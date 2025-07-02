0: Wifi Setup
	0a: iwctl									-> Starts the iwctl utility, and puts your inside a new prompt
	device list								-> List all the connection options available to you
	device wlan0 set-property Powered on    -> Turns on wlan0 (wifi module)
	station wlan0 scan						-> Scans for wifi networks
	station wlan0 get-networks				-> Lists results of the scan
	station wlan0 connect <wifi-name>     	-> Connects to provided wifi name
	<Enter you wifi password>				-> Enter password for wifi
	exit									

1. (if previous step fails) Init and populate keyring: `pacman-key --init && pacman-key --populate`
2. Update repos and install git: `pacman -Sy git`
3. Run script: cd arch-linux && chmod +x arch.sh && ./arch.sh


1: Make Disks
	1a: type 'cfdisk' - select (gpt)
	1b: Make partition (512M or 1G), thats /dev/sda1 for Boot
	1c: Make partition "minimum" of (4G), thats /dev/sda2 for Swap
	1d: Make partition for main OS, thats /dev/sda3
	1e: select [Write] - Type 'yes' - select [Quit]
	type 'lsblk' to confirm disks are set
2: Format Disks
	2a: type 'mkfs.btrfs -L arch /dev/sda3' for Main OS
			or 'mkfs.ext4' for Ext4
	2b: type 'mkfs.fat -F 32 /dev/sda1' for Boot
	2c: type 'mkswap /dev/sda2' for zRam
3: Mout File systems
	: For subvolumes. Needs BTRFS
			type'
				mount /dev/sda3 /mnt
				btrfs subvolume create /mnt/{@,@home,@log,@pkg}
				btrfs subvolume list /mnt
				mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg}
				umount /mnt
				mount -o compress=zstd:1:noatime:subvol=@ /dev/sda3 /mnt
				mount -o compress=zstd:1:noatime:subvol=@home /dev/sda3 /mnt/home
				mount -o compress=zstd:1:noatime:subvol=@log /dev/sda3 /mnt/var/log
				mount -o compress=zstd:1:noatime:subvol=@pkg /dev/sda3 /mnt/var/cache/pacman/pkg
				chattr +C /mnt/var to disbale CoW in the @var subvolume
	3a: type 'mount -o compress=zstd:1:noatime /dev/sda3 /mnt' for Main OS for "btrfs compression" set to 1
		or 'mount /dev/sda3 /mnt' for Ext4
	3b: type 'mkdir -p /mnt/boot/efi' to make boot partition
	3c: type 'mount /dev/sda1 /mnt/boot/efi' to mount boot
	3d: type 'swapon /dev/sda2' to make swap partition
	type 'lsblk' to confirm patitions are set
4: Installing base OS
	4a: type 'nano /etc/pacman.conf'
	4c: Use "[Ctrl] and [O]" to write changes - then Use [enter] to confirm - then Use "[Ctrl] and [X]" to exit Nano
	!!!pacman -Sy archlinux-keyring
	4d: type 'pacstrap /mnt base base-devel linux linux-firmware sof-firmware alsa-firmware linux-headers
		efibootmgr networkmanager btrfs-progs grub-btrfs grub os-prober amd-ucode inotify-tools pipewire pipewire-alsa pipewire-pulse reflector timeshift nano dmraid'
		;replace "linux" with "linux-zen" and "linux-zen-headers" for the zen kernal, "intel-ucode" for Intel CPUs
5: Generate Fstab
	5a: type 'genfstab /mnt' to confirm currect entries
	5b: type 'genfstab -U /mnt > /mnt/etc/fstab' to write to fstab file
6: type 'arch-chroot /mnt' to ChRoot into main OS
7: Set Time
	7a: type 'ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime' to set timezone
	type 'timedatectl set-ntp true'
	systemctl enable systemd-timesyncd
8: Set Locate
	8a: type 'nano /etc/locale.gen' to enter "locale.gen" file with Nano
	8b: select "#en_US.UTF-8" and remove the "#"
	8c: Use "[Ctrl] and [O]" to write changes - then Use [enter] to confirm - then Use "[Ctrl] and [X]" to exit Nano
	8d: type 'locale-gen' to generate locale file
	8e: type 'echo 'LANG=en_US.UTF-8' >> /etc/locale.conf' to make "locale.conf"
		or 'nano /etc/locale.conf' and add "LANG=en_US.UTF-8" with nano
		Use "[Ctrl] and [O]" to write changes - then Use [enter] to confirm - then Use "[Ctrl] and [X]" to exit Nano
9: Setting Hostname
	change "'archlinux'" to whatever you want the PC to be called
	9a: 'echo 'archlinux' >> /etc/hostname' to set a Hostname
		or 'nano /etc/hostname' and add whatever you want for PC name
		Use "[Ctrl] and [O]" to write changes - then Use [enter] to confirm - then Use "[Ctrl] and [X]" to exit Nano
10: Setting passwords and Users
	10a: type 'passwd' to set Root password
	10b: type 'useradd -m -G wheel -s /bin/bash mike'
		change "mike" to whatever you want your user name to be
	10c: type 'passwd mike' to set a password for the mike account - change "mike" to whatever your user is
	10d: type 'EDITOR=nano visudo' to enter "sudoer" file
	10e: find "# %wheel ALL=(ALL:ALL) ALL" - remove "# "
	10d: Use "[Ctrl] and [O]" to write changes - then Use [enter] to confirm - then Use "[Ctrl] and [X]" to exit Nano
11: Setting system services
	11a: 'systemctl enable NetworkManager'
12: Setting Boot
	12a: type 'grub-install /dev/sda'
	12b: type 'grub-mkconfig -o /boot/grub/grub.cfg' to set "grub boot menu"
12c: type 'exit'
13: Unmount
	13a: type 'umount -a' to unmount All drives
	13b: type 'reboot'
14: Login with you acount
15: Change "ParallelDownloads" In "# Misc options" to what you want.
	4ac: Can add at the end of "# Misc options", 'Color' 'ILoveCandy' and 'VerbosePkgLists'
	4ad: Find "# [multilib]" and uncomment "#Inclue = /etc...."
16: Setting desktop environment
	16a: type 'sudo pacman -S ark dolphin kio-admin kate konsole plasma-meta plasma-workspace sddm sddm-kcm' to install basic system
	16b: type 'sudo systemctl enable --now sddm' to enable and run system "Greeter"
17: Base System is now setup. Do some Post install stuff now.
18: 
	Edit the grub-btrfsd service, replace ExecStart=... with ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto.
	'sudo systemctl edit --full grub-btrfsd'
	#Enable grub-btrfsd service to run on boot
	'sudo systemctl enable grub-btrfsd'

OTHER:

Graphic Dri = sudo pacman -S intel-media-driver libva-intel-driver vulkan-intel vulkan-radeon xf86-video-amdgpu xf86-video-ati
	xorg-server xorg-xinit mesa libva-mesa-driver mesa-vdpau

Vmware = sudo pacman -S open-vm-tools gtkmm3
		sudo systemctl enable vmtoolsd vmware-vmblock-fuse
		sudo vmhgfs-fuse .host:/SharedFolder/ /mnt/SharedFolder/
		sudo vmhgfs-fuse .host:/SharedFolder /mnt/SharedFolder/ -o subtype=vmhgfs-fuse,allow_other

sudo pacman -S 
	  
	firefox #Fast, Private & Safe Web Browser
	gamemode #A daemon/lib combo that allows games to request a set of optimisations be temporarily applied to the host OS
	flatpak #Linux application sandboxing and distribution framework
	git #the fast distributed version control system
	cmake #A cross-platform open-source make system
	pinta ##AUR #Drawing/editing program modeled after Paint.NET. It's goal is to provide a simplified alternative to GIMP
	xwaylandvideobridge ##AUR and Flatpak #Utility to allow streaming Wayland windows to X applications
		
yay -S proton-ge-custom-bin
