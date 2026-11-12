#!/bin/bash -eE

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

board_info() {
	if [[ "$2" == "rk3576" ]]; then
		case $1 in
			armsom-sige5)
				BOARD_NAME='armsom-sige5'
				BOARD_DTB='rk3576-armsom-sige5.dtb'
				BOARD_uEnv='uEnvarmsom-sige5.txt'
				;;
			armsom-cm5-io)
				BOARD_NAME='armsom-cm5'
				BOARD_DTB='rk3576-armsom-cm5-io.dtb'
				BOARD_uEnv='uEnvarmsom-cm5-io.txt'
				;;
			armsom-aim5-io)
				BOARD_NAME='armsom-aim5-io'
				BOARD_DTB='rk3576-armsom-aim5-io.dtb'
				BOARD_uEnv='uEnvarmsom-aim5-io.txt'
				;;
			armsom-cm5-cm4-nano-b-io)
				BOARD_NAME='armsom-cm5-cm4-nano-b-io'
				BOARD_DTB='rk3576-armsom-cm5-cm4-nano-b-io.dtb'
				BOARD_uEnv='uEnvarmsom-cm5-cm4-nano-b-io.txt'
				;;
		esac
	elif [[ "$2" == "rk3588" ||  "$2" == "rk3588s" ]]; then
			case $1 in
			armsom-sige7)
				BOARD_NAME='armsom-sige7'
				BOARD_DTB='rk3588-armsom-sige7.dtb'
				BOARD_uEnv='uEnvarmsom-sige7.txt'
				;;
			armsom-sige7s)
				BOARD_NAME='armsom-sige7s'
				BOARD_DTB='rk3588s-armsom-sige7s.dtb'
				BOARD_uEnv='uEnvarmsom-sige7s.txt'
				;;
			armsom-w3)
				BOARD_NAME='armsom-w3'
				BOARD_DTB='rk3588-armsom-w3.dtb'
				BOARD_uEnv='uEnvarmsom-w3.txt'
				;;
			armsom-aim7-io)
				BOARD_NAME='armsom-aim7-io'
				BOARD_DTB='rk3588-armsom-aim7-io.dtb'
				BOARD_uEnv='uEnvarmsom-aim7-io.txt'
				;;
			armsom-cm7s-io)
				BOARD_NAME='armsom-cm7s-io'
				BOARD_DTB='rk3588s-armsom-cm7s-io.dtb'
				BOARD_uEnv='uEnvarmsom-cm7s-io.txt'
				;;
			*)
				echo "Unknown board: $1" >&2
				;;
		esac
	fi
				
	echo "BOARD_NAME:"$BOARD_NAME
	echo "BOARD_DTB:"$BOARD_DTB
	echo "BOARD_uEnv:"$BOARD_uEnv
}

board_id() {
	SOC_type=$(cat /proc/device-tree/compatible | tr -d '\0' | cut -d, -f3)
    BOARD_ID=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | cut -d ',' -f2 | cut -d '-' -f2-)
	echo "SOC_type:"$SOC_type
}


# Boot partition initialization. Reboot is owned by rockchip.sh.
. /usr/lib/armsom/first-boot-common.sh
trap 'rc=$?; echo "[boot-init] FAILED at line $LINENO: $BASH_COMMAND (exit $rc)" >&2; exit "$rc"' ERR
for tool in awk findmnt lsblk mountpoint udevadm fsck mount readlink wc python3 dpkg dpkg-deb tar cmp flock; do
    command -v "$tool" >/dev/null || { echo "Required boot initialization tool missing: $tool" >&2; exit 1; }
done
mkdir -p /run/lock
exec 8>/run/lock/armsom-boot-init.lock
flock -n 8 || { echo "Boot initialization is already running" >&2; exit 1; }
FIRST_BOOT_INIT_LOCK_HELD=1

# Validate /boot on every boot, including systems already initialized.
# Boot mount helpers are in first-boot-common.sh.
first_boot_mount_boot
first_boot_recover_kernel
[ -e /boot/boot_init ] && exit 0

board_id
board_info "$BOARD_ID" "$SOC_type"
[ -n "$BOARD_DTB" ] && [ -n "$BOARD_uEnv" ] || {
    echo "Unsupported board: $BOARD_ID ($SOC_type); boot links unchanged" >&2; exit 1;
}

# Scope partition detection to the active boot disk; a USB/SD userdata
# label must not change how this system initializes its kernel.
boot_source=$(readlink -f "$(findmnt -nro SOURCE -M /boot)")
boot_disk=$(lsblk -ndo PKNAME "$boot_source")
[ -n "$boot_disk" ] || { echo "Cannot identify the mounted boot partition disk" >&2; exit 1; }
if ! lsblk -nrpo PARTLABEL "/dev/$boot_disk" | grep -Fxq userdata; then
    # Check all inputs before installing packages or replacing working links.
    [ -f "/boot/dtb/$BOARD_DTB" ] && [ -f "/boot/uEnv/$BOARD_uEnv" ] || {
        echo "Missing board DTB/uEnv; boot links unchanged" >&2; exit 1;
    }
    first_boot_cache_debs
    shopt -s nullglob
    packages=(/var/lib/armsom/kernel-packages/linux-image-*.deb /var/lib/armsom/kernel-packages/linux-headers-*.deb)
    [ "${#packages[@]}" -gt 0 ] || { echo "Missing local kernel packages" >&2; exit 1; }
    first_boot_install_debs "${packages[@]}"
    [ -f "/boot/dtb/$BOARD_DTB" ] && [ -f "/boot/uEnv/$BOARD_uEnv" ] || {
        echo "Installed kernel lacks board DTB/uEnv; initialization incomplete" >&2
        exit 1
    }
    first_boot_link "dtb/$BOARD_DTB" /boot/rk-kernel.dtb
    first_boot_link "$BOARD_uEnv" /boot/uEnv/uEnv.txt
    if [ -f /boot/logo_kernel.bmp ]; then
        cp -f /boot/logo_kernel.bmp /boot/logo.bmp
    fi
    first_boot_request_reboot
else
    for label in oem userdata; do
        target="/$label"
        partition=$(lsblk -nrpo NAME,PARTLABEL "/dev/$boot_disk" | awk -v l="$label" '$2 == l { print $1; exit }')
        [ -n "$partition" ] || continue
        uuid=$(lsblk -ndo UUID "$partition")
        [ -n "$uuid" ] || { echo "Missing filesystem UUID for $partition" >&2; exit 1; }
        if ! awk -v t="$target" '$1 !~ /^#/ && $2 == t { found=1 } END { exit !found }' /etc/fstab; then
            first_boot_fstab_add "UUID=$uuid $target ext4 defaults 0 2"
        fi
    done
fi
first_boot_mark /boot/boot_init
first_boot_commit_kernel
