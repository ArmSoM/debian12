#!/bin/bash -e

TARGET_DIR=$1
shift

OS_RELEASE="${TARGET_DIR}/etc/os-release"

function add_build_info()
{
    [ -f "$OS_RELEASE" ] && sed -i "/^BUILD_ID=/d" "$OS_RELEASE"

    echo "Adding build-info to /etc/os-release..."
    echo "BUILD_INFO=\"$(whoami)@$(hostname) $(date)${@:+ - $@}\"" >> \
        "$OS_RELEASE"
}

echo "Executing $(basename $0)..."

add_build_info $@

# Fresh images must not start at the old base tarball/systemd build date.
# timesync/clock supports both systemd 249 (Ubuntu) and 252 (Debian).
clock_dir="$TARGET_DIR/var/lib/systemd/timesync"
chroot "$TARGET_DIR" install -d -o systemd-timesync -g systemd-timesync /var/lib/systemd/timesync
install -m 0644 /dev/null "$clock_dir/clock"
chown --reference="$clock_dir" "$clock_dir/clock"
touch "$clock_dir/clock"

exit 0
