#!/bin/bash

# Define the log file
LOGFILE="install.log"

# Start logging all output to the log file
exec > >(tee -a "$LOGFILE") 2>&1

# Log each command before executing it
log_command() {
    echo "\$ $BASH_COMMAND" >> "$LOGFILE"
}
trap log_command DEBUG

set -e

# CPU vendor
if cat /proc/cpuinfo | grep "vendor" | grep "GenuineIntel" > /dev/null; then
    export CPU_MICROCODE="intel-ucode"
	export CPU="intel"
elif cat /proc/cpuinfo | grep "vendor" | grep "AuthenticAMD" > /dev/null; then
    export CPU_MICROCODE="amd-ucode"
	export CPU="amd"
    export AMD_SCALING_DRIVER="amd_pstate=active"
fi

# GPU vendor
if lspci | grep -E "VGA|3D" | grep -q "Intel"; then
    export GPU_PACKAGES="vulkan-intel intel-media-driver intel-gpu-tools libva-intel-driver"
    export GPU_MKINITCPIO_MODULES="i915"
    export LIBVA_ENV_VAR="LIBVA_DRIVER_NAME=iHD"
	export GPU="Intel"
elif lspci | grep -E "VGA|3D" | grep -q "AMD"; then
    export GPU_PACKAGES="vulkan-radeon libva-mesa-driver radeontop mesa-vdpau xf86-video-amdgpu xf86-video-ati corectrl"
    export GPU_MKINITCPIO_MODULES="amdgpu"
    export LIBVA_ENV_VAR="LIBVA_DRIVER_NAME=radeonsi"
	export GPU="AMD"
elif lspci | grep -E "VGA|3D" | grep -q "NVIDIA"; then
    export GPU_PACKAGES="dkms nvidia-utils nvidia-dkms nvidia-settings lib32-nvidia-utils libva-vdpau-driver"
	export GPU="NVIDIA"
fi

# === USER INTERACTION PHASE ===
# Get a list of disks (excluding loop and rom)
DISKS=($(lsblk -d -e 7,11 -n -o NAME))
echo "Available disks:"
for i in "${!DISKS[@]}"; do
    MODEL=$(lsblk -d -n -o MODEL "/dev/${DISKS[$i]}")
    SIZE=$(lsblk -d -n -o SIZE "/dev/${DISKS[$i]}")
    echo "  [$i] /dev/${DISKS[$i]}  ($SIZE, $MODEL)"
done
# Ask for selection
read -p "Select the disk number to install to: " DISK_INDEX
# Validate input
if ! [[ "$DISK_INDEX" =~ ^[0-9]+$ ]] || (( DISK_INDEX < 0 || DISK_INDEX >= ${#DISKS[@]} )); then
    echo "❌ Invalid selection."
    exit 1
fi
DISK="/dev/${DISKS[$DISK_INDEX]}"
echo "⚠️ WARNING: This will ERASE ALL DATA on $DISK"
read -p "Type yes to continue: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 1


echo "Choose filesystem: (1) Btrfs, (2) Ext4"
read FS_CHOICE
[[ "$FS_CHOICE" == "1" ]] && FILESYSTEM="btrfs"
[[ "$FS_CHOICE" == "2" ]] && FILESYSTEM="ext4"
[[ -z "$FILESYSTEM" ]] && echo "Invalid option" && exit 1

read -p "Enter timezone (default: America/New_York): " TIMEZONE
[[ -z "$TIMEZONE" ]] && TIMEZONE="America/New_York"

read -p "Enter hostname (default: archlinux): " HOSTNAME
[[ -z "$HOSTNAME" ]] && HOSTNAME="archlinux"

echo "Set root password:"
read -s ROOT_PASS
read -s -p "Confirm root password: " ROOT_PASS_CONFIRM
[[ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]] && echo "Passwords don't match." && exit 1

read -p "Create a user? (yes/no): " CREATE_USER
if [[ "$CREATE_USER" == "yes" ]]; then
    read -p "Username: " USERNAME
    echo "Set password for $USERNAME:"
    read -s USER_PASS
    read -s -p "Confirm password: " USER_PASS_CONFIRM
    [[ "$USER_PASS" != "$USER_PASS_CONFIRM" ]] && echo "Passwords don't match." && exit 1
    read -p "Should $USERNAME be a sudoer? (yes/no): " SUDO_USER
fi

echo "Choose one or more Linux kernels to install (separate with spaces):"
echo "  1) Linux"
echo "  2) Linux-Zen"
echo "  3) Linux LTS"
read -p "Enter numbers (e.g., 1 3): " KERNEL_CHOICES

KERNEL_PKGS=""
for choice in $KERNEL_CHOICES; do
    case "$choice" in
        1)
            KERNEL_PKGS+=" linux linux-headers"
            ;;
        2)
            KERNEL_PKGS+=" linux-zen linux-zen-headers"
            ;;
        3)
            KERNEL_PKGS+=" linux-lts linux-lts-headers"
            ;;
        *)
            echo "⚠️  Invalid kernel choice: $choice"
            ;;
    esac
done

if [[ -z "$KERNEL_PKGS" ]]; then
    echo "⚠️  No valid kernels selected. Proceeding without a kernel package!"
fi

echo "Choose a desktop environment:"
echo "1) KDE Plasma"
echo "2) GNOME"
read -p "Enter number: " DE_CHOICE
DE_PKGS=""
DM_SERVICE=""
case $DE_CHOICE in
  1)
    DE_PKGS="plasma-meta plasma-workspace konsole dolphin kate ark kio-admin sddm sddm-kcm xdg-utils kwalletmanager egl-wayland ffmpegthumbs \
	filelight gwenview kcalc kdeconnect kdegraphics-thumbnailers kdialog"
    DM_SERVICE="sddm"
    ;;
  2)
	DE_PKGS="gnome gnome-extra gnome-tweaks gdm xdg-utils"
    DM_SERVICE="gdm"
    ;;
  *)
    echo "Invalid choice. Exiting..." && exit 1
    ;;
esac

read -p "Is this a virtual machine (yes / no): " VM_MACHINE
export VM_MACHINE

read -p "Install Gaming (yes / no): " GAMING
export GAMING

if [[ "$GAMING" == "yes" ]]; then
  read -p "Steam native (yes / no): " STEAM_NATIVE
  export STEAM_NATIVE
fi

# === PARTITION & FORMAT ===
if [[ "$DISK" == *"nvme"* ]]; then
    BOOT="${DISK}p1"
    SWAP="${DISK}p2"
    ROOT="${DISK}p3"
else
    BOOT="${DISK}1"
    SWAP="${DISK}2"
    ROOT="${DISK}3"
fi

echo "Partitioning $DISK using parted..."
parted --script $DISK \
  mklabel gpt \
  mkpart primary fat32 1MiB 513MiB \
  set 1 esp on \
  mkpart primary linux-swap 513MiB 4.5GiB \
  mkpart primary ext4 4.5GiB 100%

# Assign partitions
if [[ "$DISK" == *"nvme"* ]]; then
    BOOT="${DISK}p1"
    SWAP="${DISK}p2"
    ROOT="${DISK}p3"
else
    BOOT="${DISK}1"
    SWAP="${DISK}2"
    ROOT="${DISK}3"
fi
sleep 2  # allow kernel to register the new partitions

echo "Formatting partitions..."
mkfs.fat -F32 $BOOT
mkswap $SWAP
[[ "$FILESYSTEM" == "btrfs" ]] && mkfs.btrfs -L arch $ROOT || mkfs.ext4 -L arch $ROOT

# === MOUNT & BTRFS SUBVOLUMES ===
if [[ "$FILESYSTEM" == "btrfs" ]]; then
    mount $ROOT /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@pkg
    umount /mnt
    mount -o compress=zstd:1,noatime,subvol=@ $ROOT /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg}
    mount -o compress=zstd:1,subvol=@home $ROOT /mnt/home
    mount -o compress=zstd:1,subvol=@log $ROOT /mnt/var/log
    mount -o compress=zstd:1,subvol=@pkg $ROOT /mnt/var/cache/pacman/pkg
else
    mount $ROOT /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg}
fi
mount $BOOT /mnt/boot/efi
swapon $SWAP

# === BASE SYSTEM INSTALLATION ===
# PACMAN TEMP TWEAKS
sed -i 's/^#ParallelDownloads =.*/ParallelDownloads = 6/' /etc/pacman.conf
sed -i '/# Misc options/a Color\nILoveCandy\nVerbosePkgLists' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

pacman -Sy --noconfirm archlinux-keyring

BASE_PKGS="base base-devel $KERNEL_PKGS linux-firmware sof-firmware alsa-firmware efibootmgr networkmanager grub os-prober nano sudo htop iwd nano openssh smartmontools vim \
	wget xorg-server xorg-xinit libwnck3 xorg-xinput xorg-xkill pacman-contrib pkgfile bash-completion cpupower power-profiles-daemon \
	nano-syntax-highlighting git cmake firefox ${CPU_MICROCODE} $DE_PKGS"
	
AUDIO_PKGS="pipewire pipewire-jack pipewire-pulse pipewire-alsa alsa-plugins alsa-utils wireplumber"

NETWORK_PKGS="dnsmasq dnsutils ethtool modem-manager-gui networkmanager-openvpn nss-mdns usb_modeswitch wireless-regdb networkmanager-l2tp \
xl2tpd wireless_tools wpa_supplicant"

BLUETOOTH_PKGS="$bluez bluez-hid2hci bluez-utils"

DESKTOP_INTER_PKGS="ffmpegthumbnailer gst-libav gst-plugin-pipewire libgsf libopenraw poppler-glib vulkan-icd-loader vulkan-mesa-layers"

FILE_SYSTEM_PKGS="efitools nfs-utils ntp unrar unzip"

HARDWARE_PKGS="hwdetect lsscsi mtools sg3_utils"

MISC_PKGS="btop duf hwinfo fastfetch pv rsync"

PRINTER_PKGS="cups cups-filters cups-pdf foomatic-db foomatic-db-engine foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds gsfonts \
gutenprint foomatic-db-gutenprint-ppd splix system-config-printer hplip python-pyqt5 python-reportlab"

ACCESSIBILITY_PKGS="espeakup mousetweaks orca"

FONT_PKGS="adwaita-fonts noto-fonts noto-fonts-emoji noto-fonts-cjk noto-fonts-extra ttf-liberation otf-cascadia-code ttf-noto-nerd ttf-hack inter-font \
cantarell-fonts otf-font-awesome"

[[ "$VM_MACHINE" == "yes" ]] && BASE_PKGS="$BASE_PKGS mesa open-vm-tools gtkmm3"
[[ "$STEAM_NATIVE" == "yes" ]] && BASE_PKGS="$BASE_PKGS steam gamescope mangohud lib32-mangohud"
[[ "$FILESYSTEM" == "btrfs" ]] && BASE_PKGS="$BASE_PKGS btrfs-progs grub-btrfs timeshift"
[[ "$CPU" == "intel" ]] && BASE_PKGS="$BASE_PKGS thermald"

pacstrap /mnt $BASE_PKGS \
$AUDIO_PKGS \
$NETWORK_PKGS \
$BLUETOOTH_PKGS \
$DESKTOP_INTER_PKGS \
$FILE_SYSTEM_PKGS \
$HARDWARE_PKGS \
$MISC_PKGS \
$PRINTER_PKGS \
$ACCESSIBILITY_PKGS \
$FONT_PKGS

# === FSTAB GENERATION ===
genfstab -U /mnt > /mnt/etc/fstab

echo KERNEL is = "$KERNEL_CHOICES"
echo TIMEZONE = "$TIMEZONE"
echo HOSTNAME = "$HOSTNAME"
echo ROOT_PASS = "$ROOT_PASS"
echo CREATE_USER = "$CREATE_USER"
echo USERNAME = "$USERNAME"
echo USER_PASS = "$USER_PASS"
echo SUDO_USER = "$SUDO_USER"
echo DM_SERVICE = "$DM_SERVICE"
echo VM_MACHINE = "$VM_MACHINE"
echo FILESYSTEM = "$FILESYSTEM"
echo AUTOLOGIN = "$AUTOLOGIN"
echo STEAM_NATIVE = "$STEAM_NATIVE"
echo GPU = "$GPU"
echo GAMING is = "$GAMING"
read -p "Paused (yes / no): " PAUSE
export PAUSE
# === COPY CHROOT SETUP SCRIPT ===
echo "📄 Copying chroot setup script..."
cp setup_inside_chroot.sh /mnt/root/setup_inside_chroot.sh
chmod +x /mnt/root/setup_inside_chroot.sh

# === EXPORT ENVIRONMENT VARIABLES INTO SCRIPT ===
echo "🔧 Injecting environment variables into chroot setup script..."
cat <<EOF >> /mnt/root/setup_inside_chroot.sh

# === Injected Variables ===
export TIMEZONE="$TIMEZONE"
export HOSTNAME="$HOSTNAME"
export ROOT_PASS="$ROOT_PASS"
export CREATE_USER="$CREATE_USER"
export USERNAME="$USERNAME"
export USER_PASS="$USER_PASS"
export SUDO_USER="$SUDO_USER"
export DM_SERVICE="$DM_SERVICE"
export VM_MACHINE="$VM_MACHINE"
export FILESYSTEM="$FILESYSTEM"
export AUTOLOGIN="$AUTOLOGIN"
export STEAM_NATIVE="$STEAM_NATIVE"
export GPU="$GPU"
EOF

# === RUN THE CHROOT SCRIPT ===
echo "🚀 Running setup_inside_chroot.sh in chroot..."
arch-chroot /mnt /root/setup_inside_chroot.sh

# === CLEANUP ===
echo "🧹 Cleaning up setup_inside_chroot.sh..."
rm /mnt/root/setup_inside_chroot.sh



echo "✅ Arch Linux installation complete!"
