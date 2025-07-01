#!/bin/bash

set -e

echo "🕒 Setting timezone to $TIMEZONE..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
timedatectl set-ntp true
systemctl enable systemd-timesyncd

echo "🌐 Generating locale..."
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "🖥️ Setting hostname to $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "🔐 Setting root password..."
echo "root:$ROOT_PASS" | chpasswd

if [[ "$CREATE_USER" == "yes" ]]; then
    echo "👤 Creating user: $USERNAME"
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASS" | chpasswd

    if [[ "$SUDO_USER" == "yes" ]]; then
        echo "🛡️  Granting sudo privileges to $USERNAME"
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    fi
fi

echo "📦 Configuring pacman..."
sed -i 's/^#ParallelDownloads =.*/ParallelDownloads = 6/' /etc/pacman.conf
sed -i '/# Misc options/a Color\nILoveCandy\nVerbosePkgLists' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

echo "⚙️ Enabling system services..."
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable cpupower
systemctl enable power-profiles-daemon

[[ -n "$DM_SERVICE" ]] && {
    echo "🔌 Enabling display manager: $DM_SERVICE"
    systemctl enable "$DM_SERVICE"
}
[[ "$VM_MACHINE" == "yes" ]] && {
    echo "💻 Enabling VM services..."
    systemctl enable vmtoolsd
    systemctl enable vmware-vmblock-fuse
}
[[ "$FILESYSTEM" == "btrfs" ]] && {
    echo "📁 Enabling grub-btrfsd for Btrfs snapshots..."
    systemctl enable grub-btrfsd
}

if [[ "$CREATE_USER" == "yes" && "$AUTOLOGIN" == "yes" ]]; then
    echo "🔓 Setting up auto-login for $USERNAME..."
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

echo "🧹 Installing and configuring GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

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

echo "📦 Installing and configuring Flatpak..."
pacman -S --noconfirm flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak update -y
flatpak install -y flathub com.github.tchx84.Flatseal

[[ "$STEAM_NATIVE" == "no" ]] && {
    echo "🎮 Installing Steam via Flatpak..."
    flatpak install --noninteractive flathub com.valvesoftware.Steam
}
[[ "$GPU" == "Intel" ]] && {
    echo "📺 Installing Intel VAAPI Flatpak support..."
    flatpak install -y flathub org.freedesktop.Platform.VAAPI.Intel//24.08
}

if [[ "$GPU" == "AMD" ]]; then
    echo "🔧 Configuring CoreCtrl permissions for $USERNAME..."
    cat <<POLKIT > /etc/polkit-1/localauthority/50-local.d/90-corectrl.pkla
[User permissions]
Identity=unix-group:$USERNAME
Action=org.corectrl.*
ResultActive=yes
POLKIT
fi

echo "✅ setup_inside_chroot.sh completed successfully!"
