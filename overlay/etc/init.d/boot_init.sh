#!/bin/bash -e

### BEGIN INIT INFO
# Provides:          LubanCat
# Required-Start:
# Required-Stop:
# Default-Start:
# Default-Stop:
# Short-Description:
# Description:       This script initializes custom services or configurations at boot time.
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

board_info() {
	
	BOARD_NAME='armsom-cm5'
	BOARD_DTB='armsom-cm5-io'
	BOARD_uEnv='uEnvArmsom.txt'
				
	echo "BOARD_NAME:"$BOARD_NAME
	echo "BOARD_DTB:"$BOARD_DTB
	echo "BOARD_uEnv:"$BOARD_uEnv
}

board_id() {
	SOC_type=$(cat /proc/device-tree/compatible | cut -d,  -f 3 | sed 's/\x0//g')
	echo "SOC_type:"$SOC_type
}

board_id
board_info ${SOC_type}

# first boot configure

until [ -e "/dev/disk/by-partlabel/boot" ]
do
	echo "wait /dev/disk/by-partlabel/boot"
	sleep 0.1
done

if [ ! -e "/boot/boot_init" ] ; then
	if [ ! -e "/dev/disk/by-partlabel/userdata" ] ; then
		if [ ! -L "/boot/rk-kernel.dtb" ] ; then
			for x in $(cat /proc/cmdline); do
				case $x in
				root=*)
					Root_Part=${x#root=}
					;;
				boot_part=*)
					Boot_Part_Num=${x#boot_part=}
					;;
				esac
			done

			Boot_Part="${Root_Part::-1}${Boot_Part_Num}"
			mount "$Boot_Part" /boot
			echo "$Boot_Part  /boot  auto  defaults  0 2" >> /etc/fstab
		fi

		service lightdm stop || echo "skip error"

		apt install -fy --allow-downgrades /boot/kerneldeb/* || true
		apt-mark hold linux-headers-$(uname -r) linux-image-$(uname -r) || true

		ln -sf dtb/$BOARD_DTB /boot/rk-kernel.dtb
		ln -sf $BOARD_uEnv /boot/uEnv/uEnv.txt

		touch /boot/boot_init
		rm -f /boot/kerneldeb/*
		cp -f /boot/logo_kernel.bmp /boot/logo.bmp
		reboot
	else
		echo "PARTLABEL=oem  /oem  ext2  defaults  0 2" >> /etc/fstab
		echo "PARTLABEL=userdata  /userdata  ext2  defaults  0 2" >> /etc/fstab
		touch /boot/boot_init
	fi
fi
