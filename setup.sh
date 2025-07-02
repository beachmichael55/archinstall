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

echo "Configuring pacman..."
sed -i 's/^#ParallelDownloads =.*/ParallelDownloads = 6/' /etc/pacman.conf
sed -i '/# Misc options/a Color\nILoveCandy\nVerbosePkgLists' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

echo "Enabling system services..."

systemctl enable bluetooth
systemctl enable cpupower
systemctl enable power-profiles-daemon
[[ -n "$DM_SERVICE" ]] && {
    echo "Enabling display manager: $DM_SERVICE"
    systemctl enable "$DM_SERVICE"
}
[[ "$VM_MACHINE" == "yes" ]] && {
    echo "Enabling VM services..."
    systemctl enable vmtoolsd
    systemctl enable vmware-vmblock-fuse
}
[[ "$FILESYSTEM" == "btrfs" ]] && {
    echo "Enabling grub-btrfsd for Btrfs snapshots..."
    systemctl enable grub-btrfsd
}
[[ "$QEMU" == "yes" ]] && {
    echo "Enabling QEMU (Virtual Machine Manager ..."
    systemctl enable libvirtd
}

if [[ "$CREATE_USER" == "yes" && "$AUTOLOGIN" == "yes" ]]; then
    echo "Setting up auto-login for $USERNAME..."
    case "$DM_SERVICE" in
        sddm)
            mkdir -p /etc/sddm.conf.d
            echo -e "[Autologin]\nUser=$USERNAME\nSession=plasma.desktop" > /etc/sddm.conf.d/autologin.conf
            ;;
        gdm)
            mkdir -p /etc/gdm
            echo -e "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$USERNAME" >> /etc/gdm/custom.conf
            ;;
        lightdm)
            sed -i "s/^#autologin-user=.*/autologin-user=$USERNAME/" /etc/lightdm/lightdm.conf
            sed -i "s/^#autologin-session=.*/autologin-session=lightdm-autologin/" /etc/lightdm/lightdm.conf
            ;;
    esac
fi

# Modify mkinitcpio.conf for Btrfs and Microcode
echo "Modify mkinitcpio..."
if [[ "$FILESYSTEM" == "btrfs" ]]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck btrfs)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

if [[ "$CREATE_USER" == "yes" ]]; then
    echo "📥 Installing yay (AUR helper) for $USERNAME..."
    pacman -S --noconfirm git base-devel
    sudo -u "$USERNAME" bash -c '
        cd ~
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
    '
fi

echo "Installing and configuring Flatpak..."
pacman -S --noconfirm flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak update -y
flatpak install -y flathub com.github.tchx84.Flatseal

[[ "$STEAM_NATIVE" == "no" ]] && {
    echo "Installing Steam via Flatpak..."
    flatpak install --noninteractive flathub com.valvesoftware.Steam
}
[[ "$GPU" == "Intel" ]] && {
    echo "Installing Intel VAAPI Flatpak support..."
    flatpak install -y flathub org.freedesktop.Platform.VAAPI.Intel//24.08
}

if [[ "$GPU" == "AMD" ]]; then
    echo "Configuring CoreCtrl permissions for $USERNAME..."
    cat <<POLKIT > /etc/polkit-1/localauthority/50-local.d/90-corectrl.pkla
[User permissions]
Identity=unix-group:$USERNAME
Action=org.corectrl.*
ResultActive=yes
POLKIT
fi