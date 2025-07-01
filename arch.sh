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
read -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && echo "Aborted." && exit 1


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
#AUDIO_PKGS="$BASE_PKGS pipewire pipewire-jack pipewire-pulse pipewire-alsa alsa-plugins alsa-utils wireplumber"
#NETWORK_PKGS="$BASE_PKGS dnsmasq dnsutils ethtool modem-manager-gui networkmanager-openvpn nss-mdns usb_modeswitch wireless-regdb networkmanager-l2tp \
#xl2tpd wireless_tools wpa_supplicant"
#BLUETOOTH_PKGS="$BASE_PKGS bluez bluez-hid2hci bluez-utils"
#DESKTOP_INTER_PKGS="$BASE_PKGS ffmpegthumbnailer gst-libav gst-plugin-pipewire libgsf libopenraw poppler-glib vulkan-icd-loader vulkan-mesa-layers"
#FILE_SYSTEM_PKGS="$BASE_PKGS efitools nfs-utils ntp unrar unzip"
#HARDWARE_PKGS="$BASE_PKGS hwdetect lsscsi mtools sg3_utils"
#MISC_PKGS="$BASE_PKGS btop duf hwinfo fastfetch pv rsync"
#PRINTER_PKGS="$BASE_PKGS cups cups-filters cups-pdf foomatic-db foomatic-db-engine foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds gsfonts \
#gutenprint foomatic-db-gutenprint-ppd splix system-config-printer hplip python-pyqt5 python-reportlab"
#ACCESSIBILITY_PKGS="$BASE_PKGS espeakup mousetweaks orca"
#FONT_PKGS="$BASE_PKGS adwaita-fonts noto-fonts noto-fonts-emoji noto-fonts-cjk noto-fonts-extra ttf-liberation otf-cascadia-code ttf-noto-nerd ttf-hack inter-font \
#cantarell-fonts otf-font-awesome
[[ "$VM_MACHINE" == "yes" ]] && BASE_PKGS="$BASE_PKGS mesa open-vm-tools gtkmm3"
[[ "$STEAM_NATIVE" == "yes" ]] && BASE_PKGS="$BASE_PKGS steam gamescope mangohud lib32-mangohud"
[[ "$FILESYSTEM" == "btrfs" ]] && BASE_PKGS="$BASE_PKGS btrfs-progs grub-btrfs timeshift"
[[ "$CPU" == "intel" ]] && BASE_PKGS="$BASE_PKGS thermald"
pacstrap /mnt $BASE_PKGS

# === FSTAB GENERATION ===
genfstab -U /mnt > /mnt/etc/fstab

# === CHROOT CONFIGURATION ===
arch-chroot /mnt /bin/bash <<EOF
# Set timezone and clock
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
timedatectl set-ntp true
systemctl enable systemd-timesyncd

# Locale
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Root password
echo "root:$ROOT_PASS" | chpasswd

# User
EOF

# === USER CREATION ===
if [[ "$CREATE_USER" == "yes" ]]; then
arch-chroot /mnt /bin/bash <<EOF
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
EOF
    if [[ "$SUDO_USER" == "yes" ]]; then
        arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    fi
fi

# === PACMAN CONF TWEAKS ===
arch-chroot /mnt /bin/bash <<EOF
sed -i 's/^#ParallelDownloads =.*/ParallelDownloads = 6/' /etc/pacman.conf
sed -i '/# Misc options/a Color\nILoveCandy\nVerbosePkgLists' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
EOF

# === SYSTEM SERVICES ===
if [[ -n "$DE_PKGS" ]]; then
  arch-chroot /mnt systemctl enable $DM_SERVICE
fi
if [[ "$VM_MACHINE" == "yes" ]]; then
arch-chroot /mnt systemctl enable vmtoolsd 
arch-chroot /mnt systemctl enable vmware-vmblock-fuse
fi
if [[ "$CPU" == "intel" ]]; then
arch-chroot /mnt systemctl enable power-profiles-daemon
fi
if [[ "$FILESYSTEM" == "btrfs" ]]; then
arch-chroot /mnt systemctl enable grub-btrfsd
fi
arch-chroot /mnt systemctl enable bluetooth
arch-chroot /mnt systemctl enable NetworkManager
arch-chroot /mnt systemctl enable power-profiles-daemon
arch-chroot /mnt systemctl enable cpupower


# === AUTO LOGIN ===
if [[ "$CREATE_USER" == "yes" ]]; then
  echo -e "\nDo you want to enable auto-login for user '$USERNAME'? (yes/no):"
  read AUTOLOGIN
  if [[ "$AUTOLOGIN" == "yes" ]]; then
    case $DM_SERVICE in
      sddm)
        arch-chroot /mnt bash -c "mkdir -p /etc/sddm.conf.d && echo -e '[Autologin]\nUser=$USERNAME\nSession=plasma.desktop' > /etc/sddm.conf.d/autologin.conf"
        ;;
      gdm)
        arch-chroot /mnt bash -c "mkdir -p /etc/gdm && echo -e '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$USERNAME' >> /etc/gdm/custom.conf"
        ;;
      lightdm)
        arch-chroot /mnt bash -c "sed -i 's/^#autologin-user=.*/autologin-user=$USERNAME/' /etc/lightdm/lightdm.conf"
        arch-chroot /mnt bash -c "sed -i 's/^#autologin-session=.*/autologin-session=lightdm-autologin/' /etc/lightdm/lightdm.conf"
        ;;
    esac
  fi
fi

# === GRUB INSTALLATION ===
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# === OPTIONAL: AUR Helper (yay) and Flathub ===
if [[ "$CREATE_USER" == "yes" ]]; then
  echo -e "\nSetting up yay (AUR helper) for user '$USERNAME'..."
  arch-chroot /mnt /bin/bash <<EOF
pacman -S --noconfirm git base-devel
sudo -u $USERNAME bash -c '
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
'
EOF
fi

# === corectrl CONFIGURATION ===
if [[ "$GPU" == "AMD" ]]; then
arch-chroot /mnt /bin/bash <<EOF
cat <<CORE > /etc/polkit-1/localauthority/50-local.d/90-corectrl.pkla
[User permissions]
Identity=unix-group:your-user-group
Action=org.corectrl.*
ResultActive=yes
CORE
EOF
fi

# === FLATPAK ===
echo -e "\nInstalling Flatpak and adding Flathub..."
arch-chroot /mnt pacman -S --noconfirm flatpak
arch-chroot /mnt flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
arch-chroot /mnt flatpak update -y
arch-chroot /mnt flatpak install -y flathub com.github.tchx84.Flatseal

if [[ "$STEAM_NATIVE" == "no" ]]; then
  arch-chroot /mnt flatpak install --noninteractive flathub com.valvesoftware.Steam
fi
if [[ "$GPU" == "Intel" ]]; then
  arch-chroot /mnt flatpak install -y flathub org.freedesktop.Platform.VAAPI.Intel//24.08
fi

echo "✅ Arch Linux with ${DM_SERVICE^^} is installed!"
echo "You can now reboot into your new system."
