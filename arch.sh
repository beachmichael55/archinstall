#!/bin/bash

set -e

# CPU vendor
if cat /proc/cpuinfo | grep "vendor" | grep "GenuineIntel" > /dev/null; then
    export CPU_MICROCODE="intel-ucode"
elif cat /proc/cpuinfo | grep "vendor" | grep "AuthenticAMD" > /dev/null; then
    export CPU_MICROCODE="amd-ucode"
    export AMD_SCALING_DRIVER="amd_pstate=active"
fi

# GPU vendor
if lspci | grep "VGA" | grep "Intel" > /dev/null; then
    export GPU_PACKAGES="vulkan-intel intel-media-driver intel-gpu-tools"
    export GPU_MKINITCPIO_MODULES="i915"
    export LIBVA_ENV_VAR="LIBVA_DRIVER_NAME=iHD"
elif lspci | grep "VGA" | grep "AMD" > /dev/null; then
    export GPU_PACKAGES="vulkan-radeon libva-mesa-driver radeontop mesa-vdpau"
    export GPU_MKINITCPIO_MODULES="amdgpu"
    export LIBVA_ENV_VAR="LIBVA_DRIVER_NAME=radeonsi"
fi

# === USER INTERACTION PHASE ===

read -p "Enter target disk (e.g., /dev/sda, /dev/nvme0n1): " DISK
echo "WARNING: This will erase $DISK. Type YES to continue:"
read CONFIRM
[[ "$CONFIRM" != "YES" ]] && echo "Aborted." && exit 1

echo "Choose filesystem: (1) Btrfs, (2) Ext4"
read FS_CHOICE
[[ "$FS_CHOICE" == "1" ]] && FILESYSTEM="btrfs"
[[ "$FS_CHOICE" == "2" ]] && FILESYSTEM="ext4"
[[ -z "$FILESYSTEM" ]] && echo "Invalid option" && exit 1

echo "Enter timezone (e.g. America/New_York):"
read TIMEZONE
[[ -z "$TIMEZONE" ]] && TIMEZONE="UTC"

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

cfdisk $DISK

echo "Formatting disks..."
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

pacman -Sy --noconfirm archlinux-keyring

BASE_PKGS="base base-devel linux linux-firmware sof-firmware alsa-firmware linux-headers efibootmgr networkmanager grub os-prober nano sudo ${CPU_MICROCODE}"
[[ "$FILESYSTEM" == "btrfs" ]] && BASE_PKGS="$BASE_PKGS btrfs-progs grub-btrfs"

pacstrap /mnt $BASE_PKGS

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

# === DESKTOP ENVIRONMENT INSTALLATION ===

echo "Choose a desktop environment:"
echo "1) KDE Plasma"
echo "2) GNOME"
echo "3) XFCE"
echo "4) Cinnamon"
echo "5) MATE"
echo "6) LXQt"
echo "7) i3 (minimal)"
read -p "Enter number: " DE_CHOICE

DE_PKGS=""
DM_SERVICE=""

case $DE_CHOICE in
  1)
    DE_PKGS="plasma-meta plasma-workspace konsole dolphin kate ark kio-admin sddm sddm-kcm"
    DM_SERVICE="sddm"
    ;;
  2)
    DE_PKGS="gnome gnome-extra gdm"
    DM_SERVICE="gdm"
    ;;
  3)
    DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
    DM_SERVICE="lightdm"
    ;;
  4)
    DE_PKGS="cinnamon lightdm lightdm-gtk-greeter"
    DM_SERVICE="lightdm"
    ;;
  5)
    DE_PKGS="mate mate-extra lightdm lightdm-gtk-greeter"
    DM_SERVICE="lightdm"
    ;;
  6)
    DE_PKGS="lxqt sddm"
    DM_SERVICE="sddm"
    ;;
  7)
    DE_PKGS="i3-wm i3status dmenu xterm lightdm lightdm-gtk-greeter"
    DM_SERVICE="lightdm"
    ;;
  *)
    echo "Invalid choice. Skipping DE install."
    ;;
esac

if [[ -n "$DE_PKGS" ]]; then
  arch-chroot /mnt pacman -Sy --noconfirm $DE_PKGS
  arch-chroot /mnt systemctl enable $DM_SERVICE
fi

arch-chroot /mnt systemctl enable NetworkManager


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
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB $DISK
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

echo -e "\nInstalling Flatpak and adding Flathub..."
arch-chroot /mnt pacman -S --noconfirm flatpak
arch-chroot /mnt flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo


echo "✅ Arch Linux with KDE Plasma is installed!"
echo "You can now reboot into your new system."
