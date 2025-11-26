#!/bin/bash -e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

board_info() {
	if [[ "$2" == "rk3576" ]]; then
		case $1 in
			sige5)
				BOARD_NAME='armsom-sige5'
				BOARD_DTB='rk3576-armsom-sige5.dtb'
				BOARD_uEnv='uEnvarmsom-sige5.txt'
				;;
			cm5-io)
				BOARD_NAME='armsom-cm5'
				BOARD_DTB='rk3576-armsom-cm5-io.dtb'
				BOARD_uEnv='uEnvarmsom-cm5-io.txt'
				;;
		esac
	fi
				
	echo "BOARD_NAME:"$BOARD_NAME
	echo "BOARD_DTB:"$BOARD_DTB
	echo "BOARD_uEnv:"$BOARD_uEnv
}

board_id() {
	SOC_type=$(cat /proc/device-tree/compatible | tr -d '\0' | cut -d, -f3)
    BOARD_ID=$(cat /proc/device-tree/compatible | tr -d '\0' | cut -d ',' -f2 | cut -d 'r' -f1)
	echo "SOC_type:"$SOC_type
}

board_id
board_info ${BOARD_ID} ${SOC_type}

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
			# mount check
            if ! mountpoint -q /boot; then
                echo "挂载 /boot 分区..."
                mount "$Boot_Part" /boot
            else
                echo "/boot 分区已经挂载，跳过挂载操作"
            fi
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
