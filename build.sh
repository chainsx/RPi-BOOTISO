#!/bin/sh
# Construct a arm64+raspi2 installer.

set -e

# Download the iso
release=bionic
iso_name="ubuntu-18.04-server-arm64.iso"
wget "http://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu/releases/$release/release/$iso_name"

# Extract the files from the iso to a directory server-raspi2
7z x -oserver-raspi2 "$iso_name"

# Download the latest pi bootloader files
wget http://archive.raspberrypi.org/debian/pool/main/r/raspberrypi-firmware/raspberrypi-bootloader_1.20180417-1_armhf.deb
dpkg-deb -x raspberrypi-bootloader_1.20180417-1_armhf.deb /tmp/pi-bootloader

cd server-raspi2

# Copy the bootloader files
cp /tmp/pi-bootloader/boot/* .

# The cmdline.txt (adjust as necessary)
cat <<'EOF' > cmdline.txt
file=/cdrom/preseed/pi.seed --- quiet net.ifnames=0 dwc_otg.lpm_enable=0 modprobe.blacklist=sdhci_iproc
EOF

# The config.txt
cat <<'EOF' > config.txt
# For more options and information see:
# https://www.raspberrypi.org/documentation/configuration/config-txt/README.md

# Kernel and initramfs
kernel=install/vmlinuz-raspi2
initramfs install/initrd-raspi2.gz followkernel

# boot in AArch64 (64-bit) mode
arm_64bit=1

[pi2]
# there is no dtb file for the pi2; using the pi3's file seems to be the done thing
device_tree=bcm2710-rpi-3-b.dtb
[all]

# Please note: 
#   To use overlays, the overlays folder must be copied from 
#   /lib/firmware/4.XX.X-XXXX-raspi2/device-tree/
#   !This is not automatically updated by the flash-kernel pacakge!

# Enable audio (loads snd_bcm2835)
dtparam=audio=on
EOF

# Run 'unix2dos config.txt' if you want it readable in windows

# Create preseed files
mkdir -p preseed
cd preseed

cat <<'EOF' > pi.seed 
# Ignore "no kernel modules were found for this kernel"
d-i anna/no_kernel_modules boolean true

# The partitioning scheme to be used
d-i partman-partitioning/default_label select msdos
d-i partman-auto/expert_recipe_file string /cdrom/preseed/raspberry/pi_recipe

# Maximum size of swapfile in MiB
d-i partman-swapfile/size string 1024

# Maximum percentage of free space to use for swapfile
d-i partman-swapfile/percentage text 10

# Kernel options to be used for the insalled system (added to those used with the installer)
d-i debian-installer/add-kernel-opts string elevator=deadline rootwait ro

# We'll use the pi's own bootloader
d-i grub-installer/skip boolean true

# Don't pause for the "No boot loader installed" message
d-i nobootloader/confirmation_common note

# Setup fat firmware partition (replicates the work of flash-kernel-installer)
d-i preseed/late_command string /cdrom/preseed/raspberry/pi_late_command

# Adjust installer options for the pi
d-i partman/early_command string /cdrom/preseed/raspberry/pi_partman_command
EOF

mkdir raspberry
cd raspberry

cat <<'EOF' > pi_recipe 
raspberrypi ::

128 128 128 fat32
	$primary{ }
	$bootable{ }
	method{ format }
	format{ }
	use_filesystem{ }
	filesystem{ fat32 }
	label{ pi-boot }
	mountpoint{ /boot/firmware } .

900 10000 -1 $default_filesystem
	$lvmok{ }
	$primary{ }
	method{ format }
	format{ }
	use_filesystem{ }
	$default_filesystem{ }
	label{ pi-rootfs }
	mountpoint{ / } .
EOF

cat <<'EOF' > pi_partman_command
#!/bin/sh
# Remove partman options that aren't suitable for the pi bootloader

set -e

# Replace option creates duplicate boot partitions so just get rid 
rm -r /lib/partman/automatically_partition/25replace || true

# We don't have the ability to select an os like you can with grub2 etc
rm -r /lib/partman/automatically_partition/10resize_use_free || true

# Disable flash-kernel-installer
echo "#!/bin/sh" > /var/lib/dpkg/info/flash-kernel-installer.isinstallable
echo "exit 1" >> /var/lib/dpkg/info/flash-kernel-installer.isinstallable
chmod +x /var/lib/dpkg/info/flash-kernel-installer.isinstallable
EOF

cat <<'STOP' > pi_late_command 
#!/bin/sh
# Install Raspberry Pi firmware.  Written by Adam Smith
#
# (Some bits are borrowed from flash-kernel-installer)

set -e

findfs () {
	mount | grep "on /target${1%/} " | tail -n1 | cut -d' ' -f1
}

# Check if the installer diverted update-initramfs, revert before we move on
if [ -e /target/usr/sbin/update-initramfs.flash-kernel-diverted ];then
	logger -t late_command "Removing update-initramfs diversion"
	rm -f /target/usr/sbin/update-initramfs
	in-target dpkg-divert --remove --local --rename /usr/sbin/update-initramfs
fi

logger -t late_command "Installing raspi2 kernel"

# We don't want flash-kernel run before the database is updated
chroot /target dpkg-divert --divert /usr/sbin/flash-kernel.real --rename /usr/sbin/flash-kernel

# Install the raspi2 kernel
mount -o bind /dev /target/dev
if ! apt-install linux-raspi2; then
	# Fallback to cdrom debs
	debs=""
	for i in /cdrom/preseed/raspberry/kernel-debs/*.deb ; do
		debs="$debs /media/$i"
	done
	in-target dpkg -i $debs 
fi
umount /target/dev || true

logger -t late_command "Removing generic kernel"

old_kernel="$(readlink /target/boot/vmlinuz.old | sed 's,^vmlinuz-,,g')"
in-target apt-get --autoremove --yes purge linux-generic linux-image-generic linux-headers-generic linux-image-$old_kernel linux-headers-$old_kernel linux-modules-$old_kernel linux-modules-extra-$old_kernel

logger -t success_command "Copying wifi firmware"

# Copy wifi-firmware and ensure it is not overwritten
# !Users will have to manually update!
for i in /cdrom/preseed/raspberry/wifi-firmware/*sdio* ; do
	[ -f "$i" ] || continue
	chroot /target dpkg-divert --divert "/lib/firmware/brcm/$(basename "$i").bak" --rename "/lib/firmware/brcm/$(basename "$i")" 
	cp "$i" /target/lib/firmware/brcm/
	chmod 644 "/target/lib/firmware/brcm/$(basename "$i")"
done

# The Pi doesn't have a parallel port
if [ -e  /target/etc/modules-load.d/cups-filters.conf ];then
	logger -t late_command "Removing cups-filters.conf"
	rm /target/etc/modules-load.d/cups-filters.conf
fi

logger -t late_command "Copying bootloader files"

# If the correct mount points are used there should already be a firmware directory
mkdir -p /target/boot/firmware/

# Copy bootloader files
cp /cdrom/bootcode.bin /target/boot/firmware/
cp /cdrom/fixup*.dat /target/boot/firmware/
cp /cdrom/start*.elf /target/boot/firmware/
cp /cdrom/config.txt /target/boot/firmware/

# Update config.txt
sed -i 's/^kernel=.*/kernel=vmlinuz/g' /target/boot/firmware/config.txt
sed -i 's/^initramfs .*/initramfs initrd.img followkernel/g' /target/boot/firmware/config.txt

# Create cmdline.txt file
user_params="$(echo $(user-params))" || true
vol_id=$(blkid -o value -s UUID $(findfs /))
echo "root=UUID=$vol_id $user_params" > /target/boot/firmware/cmdline.txt

logger -t late_command "Running flash-kernel ..."

# Remove flash-kernel diversion
chroot /target dpkg-divert --rename --remove /usr/sbin/flash-kernel

# Install flash-kernel if it hasn't already been
if ! apt-install flash-kernel u-boot-tools; then
	logger -t late_command "error: apt-install flash-kernel u-boot-tools failed"
	exit 1
fi

# Check flash-kernel databases and add entry if necessary
machine="$(cat /proc/device-tree/model)"
if ! { grep -q "$machine" /target/usr/share/flash-kernel/db/all.db || grep -q "$machine" /target/etc/flash-kernel/db; } || \
	echo "$machine" | grep -q "Raspberry Pi 2"; then
		# Make a guess about the dtb file to use
		case "$machine" in
			'Raspberry Pi 2 Model B'*)
				# In arm64 there is no dtb file for the pi2; using the pi3's file seems to be the done thing
				dtb="bcm2710-rpi-3-b.dtb"
			;;
			'Raspberry Pi 3 Model B Plus'*)
				dtb="bcm2710-rpi-3-b-plus.dtb"
			;;
			'Raspberry Pi 3 Model B'*)
				dtb="bcm2710-rpi-3-b.dtb"
			;;
			*)
				logger -t late_command "error: unknown model"
				exit 1
		esac

		cat <<EOF >> /target/etc/flash-kernel/db

# Automatically added by the installer
Machine: $machine
DTB-Id: $dtb
Boot-DTB-Path: /boot/firmware/$dtb
Boot-Kernel-Path: /boot/firmware/vmlinuz
Boot-Initrd-Path: /boot/firmware/initrd.img
EOF
fi

# Use flash-kernel to copy kernel, initrd.img, dtb file, etc to the boot partition
mount -o bind /dev /target/dev
if ! in-target flash-kernel; then
	# Run out of space on boot partition or missing dtb file?
	logger -t late_command "error: flash-kernel failed"
	umount /target/dev || true
	exit 1
fi
umount /target/dev || true

logger -t late_command "flash-kernel successful"
STOP

# Download wifi firmware
mkdir wifi-firmware
cd wifi-firmware
# Pi 3B
wget https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac43430-sdio.bin
wget https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac43430-sdio.txt
# Pi 3B+
wget https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac43455-sdio.bin
wget https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac43455-sdio.clm_blob
wget https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac43455-sdio.txt 

# Download raspi2 kernel debs (these probably should be saved in pool)
cd ..
mkdir kernel-debs
cd kernel-debs
wget https://launchpad.net/ubuntu/+source/linux-raspi2/4.15.0-1010.11/+build/14791518/+files/linux-image-4.15.0-1010-raspi2_4.15.0-1010.11_arm64.deb
wget https://launchpad.net/ubuntu/+source/linux-raspi2/4.15.0-1010.11/+build/14791518/+files/linux-modules-4.15.0-1010-raspi2_4.15.0-1010.11_arm64.deb
wget https://launchpad.net/ubuntu/+source/linux-meta-raspi2/4.15.0.1010.9/+build/14796074/+files/linux-image-raspi2_4.15.0.1010.9_arm64.deb

# Extract vmlinuz-raspi2 and dtb files
dpkg-deb -x linux-image-[0-9]*.deb /tmp/pi-kernel
dpkg-deb -x linux-modules-[0-9]*.deb /tmp/pi-kernel
cd ../../../
version="$(ls /tmp/pi-kernel/boot/vmlinuz* | sed 's,^\/tmp\/pi-kernel\/boot\/vmlinuz-,,g')"
cp /tmp/pi-kernel/lib/firmware/$version/device-tree/broadcom/bcm2710*.dtb .
cp /tmp/pi-kernel/boot/vmlinuz-$version install/vmlinuz-raspi2

# Create raspi2 initrd
zcat -k install/initrd.gz > install/initrd-raspi2

# Prepare to include wifi-firmware in initrd
mkdir -p /tmp/pi-kernel/lib/firmware/brcm/
chmod 755 /tmp/pi-kernel/lib/firmware/brcm/
cp preseed/raspberry/wifi-firmware/*sdio* /tmp/pi-kernel/lib/firmware/brcm/
chmod 644 /tmp/pi-kernel/lib/firmware/brcm/*

# evbug spams the logs, get rid
rm /tmp/pi-kernel/lib/modules/$version/kernel/drivers/input/evbug.ko || true

# Generate modules.dep etc files
depmod -a -b /tmp/pi-kernel -F /tmp/pi-kernel/boot/System.map-$version $version

# Remove unneeded files
rm -r /tmp/pi-kernel/lib/modules/$version/initrd || true
rm -r /tmp/pi-kernel/boot
rm -r /tmp/pi-kernel/usr
rm -r /tmp/pi-kernel/lib/firmware/$version

# Add raspi2 modules/firmware to the initrd and compress
find /tmp/pi-kernel/.  | sed 's,^/tmp/pi-kernel\/,,g'| cpio -D /tmp/pi-kernel -R +0:+0 -H newc -o -A -F install/initrd-raspi2
gzip install/initrd-raspi2

echo "Finished!"
echo "Copy all files (including the hidden .disk folder) in the server-raspi2 folder to a fat formatted usb drive."
