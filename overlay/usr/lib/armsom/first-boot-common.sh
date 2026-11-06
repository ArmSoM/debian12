#!/bin/bash
# Small shared helpers; failed initialization must remain retryable.
first_boot_mark()
{
    local tmp
    tmp=$(mktemp "${1}.XXXXXX")
    printf '%s\n' "${2:-$(cat /proc/sys/kernel/random/boot_id)}" > "$tmp"
    sync -f "$tmp"
    mv -f "$tmp" "$1"
    sync -f "$(dirname "$1")"
}

first_boot_request_reboot() { first_boot_mark /var/lib/armsom/first-boot-reboot; }

first_boot_recover_kernel()
{
    local backup
    [ -f /var/lib/armsom/kernel-install-backup ] || return 0
    backup=$(cat /var/lib/armsom/kernel-install-backup)
    [[ "$backup" =~ ^/var/lib/armsom/kernel-backup\.[[:alnum:]]+$ ]] || return 1
    [ -f "$backup/boot.tar" ] && [ -f "$backup/modules.tar" ] || return 1
    echo "Restoring interrupted kernel installation from $backup" >&2
    tar -xpf "$backup/boot.tar" -C /boot
    tar -xpf "$backup/modules.tar" -C /
    rm -f /boot/build-host /var/lib/armsom/kernel-install-backup
    sync
}

first_boot_cache_debs()
{
    local source destination version previous='' package
    local incoming=() cached=()
    mkdir -p /var/lib/armsom/kernel-packages
    shopt -s nullglob
    incoming=(/boot/kerneldeb/linux-image-*.deb /boot/kerneldeb/linux-headers-*.deb)
    [ "${#incoming[@]}" -gt 0 ] || return 0
    version=$(dpkg-deb -f "${incoming[0]}" Version)
    for source in "${incoming[@]}"; do
        [ "$(dpkg-deb -f "$source" Version)" = "$version" ] || return 1
    done
    # A rebuilt boot image takes precedence over packages in a cached rootfs.
    # Retain superseded packages for recovery rather than mixing generations.
    cached=(/var/lib/armsom/kernel-packages/linux-image-*.deb /var/lib/armsom/kernel-packages/linux-headers-*.deb)
    for package in "${cached[@]}"; do
        if [ "$(dpkg-deb -f "$package" Version)" != "$version" ]; then
            [ -n "$previous" ] || previous=$(mktemp -d /var/lib/armsom/kernel-packages/previous.XXXXXX)
            mv -- "$package" "$previous/"
        fi
    done
    for source in "${incoming[@]}"; do
        destination=/var/lib/armsom/kernel-packages/${source##*/}
        cp -- "$source" "$destination.tmp"
        cmp -- "$source" "$destination.tmp"
        sync -f "$destination.tmp"
        mv -f -- "$destination.tmp" "$destination"
        sync -f /var/lib/armsom/kernel-packages
        rm -- "$source"
    done
}

first_boot_install_debs()
{
    local package name version image='' release backup needed available rc=0
    local names=() versions=() images=() headers=()
    for package in "$@"; do
        name=$(dpkg-deb -f "$package" Package)
        version=$(dpkg-deb -f "$package" Version)
        [ "$(dpkg-deb -f "$package" Architecture)" = "$(dpkg --print-architecture)" ]
        names+=("$name"); versions+=("$version")
        case "$name" in
            linux-image-*) images+=("$package"); image=$package; release=${name#linux-image-} ;;
            linux-headers-*) headers+=("$package") ;;
            *) echo "Unexpected initialization package: $name" >&2; return 1 ;;
        esac
    done
    [ "${#images[@]}" = 1 ] && [ "${#headers[@]}" = 1 ]
    [ "$(dpkg-deb -f "${headers[0]}" Version)" = "$(dpkg-deb -f "$image" Version)" ]
    [ "$(dpkg-deb -f "${headers[0]}" Package)" = "linux-headers-$release" ]
    # Check dependencies without network access or changing the package database.
    dpkg --no-act --install "$@"
    first_boot_check_space "$image"
    needed=$(du -sk /boot /lib/modules/"$(uname -r)" | awk '{s+=$1} END {print s}')
    for package in "$@"; do needed=$((needed + $(dpkg-deb -f "$package" Installed-Size))); done
    available=$(df -Pk /var/lib/armsom | awk 'END {print $4}')
    [ "$available" -gt "$((needed + 65536))" ] || { echo "Insufficient root space for installation and recovery" >&2; return 1; }
    backup=$(mktemp -d /var/lib/armsom/kernel-backup.XXXXXX)
    tar -cpf "$backup/boot.tar" -C /boot .
    tar -cpf "$backup/modules.tar" -C / "lib/modules/$(uname -r)"
    sync -f /var/lib/armsom
    # Suppress the package's board-selection hook; this caller owns boot links.
    [ ! -e /boot/build-host ] || { echo "Unexpected build-host marker" >&2; return 1; }
    first_boot_mark /var/lib/armsom/kernel-install-backup "$backup"
    touch /boot/build-host
    DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1 dpkg --install "$@" || rc=$?
    rm -f /boot/build-host
    for ((i=0; i<${#names[@]}; i++)); do
        [ "$(dpkg-query -W -f='${Status} ${Version}' "${names[i]}")" = "install ok installed ${versions[i]}" ] || rc=1
    done
    if [ "$rc" != 0 ]; then
        echo "Kernel installation failed; restoring boot files/modules from $backup. DEBs retained for repair." >&2
        first_boot_recover_kernel
        return "$rc"
    fi
    first_boot_mark /var/lib/armsom/first-boot-kernel-release "$release"
    apt-mark hold "${names[@]}"
    rm -f /var/lib/armsom/kernel-install-backup
    sync -f /var/lib/armsom
}

first_boot_link()
{
    local temporary
    temporary=$(mktemp -d "$(dirname "$2")/.armsom-link.XXXXXX")
    ln -s "$1" "$temporary/link"
    mv -Tf "$temporary/link" "$2"
    rmdir "$temporary"
    sync -f "$(dirname "$2")"
}

first_boot_fstab_add()
{
    local temporary
    temporary=$(mktemp /etc/fstab.XXXXXX)
    cp -p /etc/fstab "$temporary"
    printf '%s\n' "$1" >> "$temporary"
    sync -f "$temporary"
    mv -f "$temporary" /etc/fstab
    sync -f /etc
}

# /boot is selected from the running root filesystem, never by a global UUID.
first_boot_mount_boot()
{
    local root_device root_disk boot_device boot_disk boot_number="" arg
    local candidates mounted_source mounted_options temporary check_status
    udevadm settle --timeout=30
    root_device=$(findmnt -nro SOURCE -T /)
    root_device=$(readlink -f "$root_device")
    [ -b "$root_device" ] || { echo "Cannot resolve running root block device: $root_device" >&2; return 1; }
    [ "$(lsblk -ndo TYPE "$root_device")" = part ] || {
        echo "Unsupported root layout: expected a physical disk partition" >&2; return 1;
    }
    root_disk=$(lsblk -ndo PKNAME "$root_device")
    [ -n "$root_disk" ] && [ -b "/dev/$root_disk" ] || {
        echo "Cannot identify running root disk" >&2; return 1;
    }
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            boot_part=*)
                [ -z "$boot_number" ] || { echo "Duplicate boot_part arguments" >&2; return 1; }
                boot_number=${arg#boot_part=}
                [[ "$boot_number" =~ ^[1-9][0-9]{0,2}$ ]] || {
                    echo "Invalid boot_part: $boot_number" >&2; return 1;
                }
                ;;
        esac
    done
    if [ -n "$boot_number" ]; then
        case "$root_disk" in
            *[0-9]) boot_device="/dev/${root_disk}p${boot_number}" ;;
            *) boot_device="/dev/${root_disk}${boot_number}" ;;
        esac
    else
        candidates=$(lsblk -nrpo NAME,PARTLABEL "/dev/$root_disk" | awk '$2 == "boot" { print $1 }')
        [ -n "$candidates" ] && [ "$(printf '%s\n' "$candidates" | wc -l)" -eq 1 ] || {
            echo "Expected exactly one boot partition on /dev/$root_disk" >&2; return 1;
        }
        boot_device=$candidates
    fi
    boot_device=$(readlink -f "$boot_device")
    [ -b "$boot_device" ] && [ "$boot_device" != "$root_device" ] || {
        echo "Invalid boot partition: $boot_device" >&2; return 1;
    }
    boot_disk=$(lsblk -ndo PKNAME "$boot_device")
    [ "$boot_disk" = "$root_disk" ] && [ "$(lsblk -ndo TYPE "$boot_device")" = part ] || {
        echo "Boot partition must belong to the running root disk" >&2; return 1;
    }

    # Retire legacy fstab entries: cloned filesystems have identical UUIDs.
    # The platform initializer mounts /boot explicitly on every boot, before
    # any kernel package installation or inspection of /boot/boot_init.
    if awk '$1 !~ /^#/ && $2 == "/boot" { found=1 } END { exit !found }' /etc/fstab; then
        [ -e /etc/fstab.armsom-before-boot-mount ] || cp -p /etc/fstab /etc/fstab.armsom-before-boot-mount
        temporary=$(mktemp /etc/fstab.XXXXXX)
        cp -p /etc/fstab "$temporary"
        awk '!($1 !~ /^#/ && $2 == "/boot")' /etc/fstab > "$temporary"
        sync -f "$temporary"
        mv -f "$temporary" /etc/fstab
        sync -f /etc
        echo "[boot-mount] Removed legacy /boot fstab entry; original saved in /etc/fstab.armsom-before-boot-mount"
    fi

    if mountpoint -q /boot; then
        mounted_source=$(findmnt -nro SOURCE -M /boot)
        mounted_source=$(readlink -f "$mounted_source")
        [ "$mounted_source" = "$boot_device" ] || {
            echo "Wrong /boot mount: $mounted_source; expected $boot_device. No boot files modified. Reboot after fstab migration to select the correct partition." >&2
            return 1
        }
    else
        # Never check/repair a filesystem already mounted at another target.
        if findmnt -rn -S "$boot_device" >/dev/null; then
            echo "Boot device $boot_device is already mounted elsewhere" >&2; return 1
        fi
        case "$(lsblk -ndo FSTYPE "$boot_device")" in
            ext2|ext3|ext4|vfat) ;;
            *) echo "Unsupported or missing boot filesystem: $boot_device" >&2; return 1 ;;
        esac
        check_status=0
        fsck -a "$boot_device" || check_status=$?
        [ "$check_status" -le 1 ] || {
            echo "Boot filesystem check failed (status $check_status); mount cancelled" >&2; return 1;
        }
        mkdir -p /boot
        mount "$boot_device" /boot
    fi
    mounted_source=$(readlink -f "$(findmnt -nro SOURCE -M /boot)")
    [ "$mounted_source" = "$boot_device" ] || {
        echo "Boot source changed during validation; refusing initialization" >&2; return 1;
    }
    mounted_options=$(findmnt -nro OPTIONS -M /boot)
    case ",$mounted_options," in
        *,rw,*) ;;
        *) echo "Boot filesystem is not writable" >&2; return 1 ;;
    esac
    echo "[boot-mount] Verified root=$root_device boot=$boot_device disk=/dev/$root_disk"
}

first_boot_check_space()
{
    python3 - "$1" <<'PY'
"""Account for dpkg temporary boot files without touching the filesystem."""
import os
import pathlib
import subprocess
import sys
import tarfile

p = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', sys.argv[1]], stdout=subprocess.PIPE)
growth = largest = 0
with tarfile.open(fileobj=p.stdout, mode='r|') as archive:
    for entry in archive:
        path = pathlib.PurePosixPath(entry.name)
        if '..' in path.parts or path.is_absolute():
            raise SystemExit('Unsafe package path')
        if entry.isfile() and path.parts[:1] == ('boot',):
            target = pathlib.Path('/') / str(path)
            old = target.stat().st_size if target.is_file() else 0
            growth += max(0, entry.size - old)
            largest = max(largest, entry.size)
if p.wait():
    raise SystemExit('Cannot inspect kernel package')
v = os.statvfs('/boot')
required = growth + largest + 8 * 1024 * 1024
if v.f_bavail * v.f_frsize < required:
    raise SystemExit(f'Insufficient /boot space: need {required} free bytes; existing boot files untouched')
PY
}
