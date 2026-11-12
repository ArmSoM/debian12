#!/bin/bash
# Small shared helpers; failed initialization must remain retryable.
first_boot_error()
{
    printf '[first-boot] %s\n' "$*" >&2
}

first_boot_mark()
{
    local tmp value
    value=${2:-$(cat /proc/sys/kernel/random/boot_id)}
    [ -n "$value" ] || { first_boot_error "Empty state for $1"; return 1; }
    tmp=$(mktemp "${1}.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" || return 1
    sync -f "$tmp" || return 1
    mv -f -- "$tmp" "$1" || return 1
    sync -f "$(dirname "$1")" || return 1
}

first_boot_request_reboot()
{
    first_boot_mark /var/lib/armsom/first-boot-reboot
}

# Read-only validation: recovery must never mount, fsck or edit fstab.
first_boot_validate_mounted_boot()
{
    local expected source options
    expected=$(first_boot_boot_device) || return 1
    mountpoint -q /boot || {
        first_boot_error "Recovery requires a mounted /boot; journal retained"
        return 1
    }
    source=$(findmnt -nro SOURCE -M /boot) || return 1
    source=$(readlink -f "$source") || return 1
    [ "$source" = "$expected" ] || {
        first_boot_error "Wrong /boot source: $source; expected $expected; journal retained"
        return 1
    }
    options=$(findmnt -nro OPTIONS -M /boot) || return 1
    case ",$options," in
        *,rw,*) ;;
        *) first_boot_error "Read-only /boot; journal retained"; return 1 ;;
    esac
}

# The disk is selected relative to the running root, not by a global UUID lookup.
# PARTUUID/UUID bind a new recovery journal to that partition across reboots.
first_boot_boot_identity()
{
    local device identity
    device=$(first_boot_boot_device) || return 1
    identity=$(lsblk -dnro PARTUUID,UUID "$device") || return 1
    [ -n "${identity//[[:space:]]/}" ] || {
        first_boot_error "Cannot identify boot partition $device"
        return 1
    }
    printf '%s\n' "$identity"
}

first_boot_read_backup()
{
    local backup
    backup=$(cat /var/lib/armsom/kernel-install-backup) || return 1
    [[ "$backup" =~ ^/var/lib/armsom/kernel-backup\.[[:alnum:]]+$ ]] &&
        [ -d "$backup" ] && [ ! -L "$backup" ] || {
        first_boot_error "Invalid recovery journal; no files restored"
        return 1
    }
    printf '%s\n' "$backup"
}

first_boot_validate_backup_identity()
{
    local backup=$1 identity saved
    # Old journals have no partition identity. Do not guess their destination.
    [ -f "$backup/boot.identity" ] || {
        first_boot_error "Legacy recovery journal lacks boot.identity; manual recovery required: $backup"
        return 1
    }
    identity=$(first_boot_boot_identity) || return 1
    saved=$(cat "$backup/boot.identity") || return 1
    [ "$identity" = "$saved" ] || {
        first_boot_error "Recovery partition identity mismatch; journal retained"
        return 1
    }
}

first_boot_recover_kernel()
(
    # A subshell releases this lock even when a recovery operation fails.
    [ -f /var/lib/armsom/kernel-install-backup ] || return 0
    if [ "${FIRST_BOOT_INIT_LOCK_HELD:-0}" != 1 ]; then
        exec 8>/run/lock/armsom-boot-init.lock || return 1
        flock -n 8 || {
            first_boot_error "Boot initialization is busy; recovery deferred"
            return 1
        }
    fi
    local backup state
    backup=$(first_boot_read_backup) || return 1
    first_boot_validate_mounted_boot || return 1
    first_boot_validate_backup_identity "$backup" || return 1
    if [ -f "$backup/committed" ]; then
        # Commit is durable before journal removal. Never undo a committed boot.
        [ -e /boot/boot_init ] || {
            first_boot_error "Committed boot marker missing; journal retained"
            return 1
        }
        rm -f /var/lib/armsom/kernel-install-backup || return 1
        sync -f /var/lib/armsom || return 1
        return 0
    fi
    # Validate all archives and state snapshots before the first restore write.
    tar -tf "$backup/boot.tar" >/dev/null || return 1
    tar -tf "$backup/modules.tar" >/dev/null || return 1
    for state in first-boot-kernel-release first-boot-reboot; do
        [ -f "$backup/$state" ] || [ -f "$backup/$state.absent" ] || {
            first_boot_error "Incomplete recovery state: $state"
            return 1
        }
    done
    echo "Restoring interrupted kernel installation from $backup" >&2
    tar -xpf "$backup/boot.tar" -C /boot || return 1
    tar -xpf "$backup/modules.tar" -C / || return 1
    # The transaction starts before boot_init exists. A partial commit must retry.
    rm -f /boot/build-host /boot/boot_init || return 1
    for state in first-boot-kernel-release first-boot-reboot; do
        if [ -f "$backup/$state.absent" ]; then
            rm -f "/var/lib/armsom/$state" || return 1
        else
            cp -p -- "$backup/$state" "/var/lib/armsom/$state" || return 1
        fi
    done
    # This restores bootability, not the entire dpkg database. Retained DEBs are
    # reinstalled on retry; never mark the interrupted initialization complete.
    sync || return 1
    rm -f /var/lib/armsom/kernel-install-backup || return 1
    sync -f /var/lib/armsom || return 1
)

first_boot_commit_kernel()
{
    local backup
    [ -f /var/lib/armsom/kernel-install-backup ] || return 0
    backup=$(first_boot_read_backup) || return 1
    first_boot_validate_mounted_boot || return 1
    first_boot_validate_backup_identity "$backup" || return 1
    [ -e /boot/boot_init ] || {
        first_boot_error "Cannot commit an incomplete boot stage"
        return 1
    }
    sync || return 1
    first_boot_mark "$backup/committed" || return 1
    rm -f /var/lib/armsom/kernel-install-backup || return 1
    sync -f /var/lib/armsom || return 1
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
    local package name version image='' release backup needed available state size sizes space i rc=0
    local names=() versions=() images=() headers=()
    [ "$#" -eq 2 ] || { first_boot_error "Expected one image and one headers package"; return 1; }
    [ ! -e /var/lib/armsom/kernel-install-backup ] || {
        first_boot_error "Pending kernel recovery must finish before installation"
        return 1
    }
    for package in "$@"; do
        name=$(dpkg-deb -f "$package" Package) || return 1
        version=$(dpkg-deb -f "$package" Version) || return 1
        [ "$(dpkg-deb -f "$package" Architecture)" = "$(dpkg --print-architecture)" ] || {
            first_boot_error "Package architecture mismatch: $package"
            return 1
        }
        names+=("$name"); versions+=("$version")
        case "$name" in
            linux-image-*) images+=("$package"); image=$package; release=${name#linux-image-} ;;
            linux-headers-*) headers+=("$package") ;;
            *) echo "Unexpected initialization package: $name" >&2; return 1 ;;
        esac
    done
    [ "${#images[@]}" -eq 1 ] && [ "${#headers[@]}" -eq 1 ] || {
        first_boot_error "Expected exactly one kernel image and one headers package"
        return 1
    }
    [ "${versions[0]}" = "${versions[1]}" ] || {
        first_boot_error "Kernel image and headers versions differ"
        return 1
    }
    [ "$(dpkg-deb -f "${headers[0]}" Package)" = "linux-headers-$release" ] || {
        first_boot_error "Kernel image and headers releases differ"
        return 1
    }
    first_boot_validate_mounted_boot || return 1
    [ ! -e /boot/boot_init ] || {
        first_boot_error "Refusing to initialize an already committed boot stage"
        return 1
    }
    [ ! -e /boot/build-host ] || { first_boot_error "Unexpected build-host marker"; return 1; }
    # Check dependencies without network access or changing the package database.
    dpkg --no-act --install "$@" || return 1
    first_boot_check_space "$image" || return 1
    sizes=$(du -sk /boot /lib/modules/"$(uname -r)") || return 1
    needed=$(printf '%s\n' "$sizes" | awk '{s+=$1} END {print s}') || return 1
    for package in "$@"; do
        size=$(dpkg-deb -f "$package" Installed-Size) || return 1
        [[ "$size" =~ ^[0-9]+$ ]] || { first_boot_error "Invalid package size: $package"; return 1; }
        needed=$((needed + size))
    done
    space=$(df -Pk /var/lib/armsom) || return 1
    available=$(printf '%s\n' "$space" | awk 'END {print $4}') || return 1
    [ "$available" -gt "$((needed + 65536))" ] || { echo "Insufficient root space for installation and recovery" >&2; return 1; }
    backup=$(mktemp -d /var/lib/armsom/kernel-backup.XXXXXX) || return 1
    tar -cpf "$backup/boot.tar" -C /boot . || return 1
    tar -cpf "$backup/modules.tar" -C / "lib/modules/$(uname -r)" || return 1
    sync -f /var/lib/armsom || return 1
    first_boot_boot_identity > "$backup/boot.identity" || return 1
    for state in first-boot-kernel-release first-boot-reboot; do
        if [ -e "/var/lib/armsom/$state" ]; then
            cp -p -- "/var/lib/armsom/$state" "$backup/$state" || return 1
        else
            touch "$backup/$state.absent" || return 1
        fi
    done
    sync -f /var/lib/armsom || return 1
    # Suppress the package's board-selection hook; this caller owns boot links.
    first_boot_mark /var/lib/armsom/kernel-install-backup "$backup" || return 1
    touch /boot/build-host || return 1
    DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1 dpkg --install "$@" || rc=$?
    rm -f /boot/build-host || return 1
    for ((i=0; i<${#names[@]}; i++)); do
        [ "$(dpkg-query -W -f='${Status} ${Version}' "${names[i]}")" = "install ok installed ${versions[i]}" ] || rc=1
    done
    if [ "$rc" != 0 ]; then
        echo "Kernel installation failed; restoring boot files/modules from $backup. DEBs retained for repair." >&2
        first_boot_recover_kernel || first_boot_error "Recovery deferred; journal retained"
        return "$rc"
    fi
    first_boot_mark /var/lib/armsom/first-boot-kernel-release "$release" || return 1
    apt-mark hold "${names[@]}" || return 1
    # boot_init.sh commits after links, reboot request and boot marker are durable.
    sync -f /var/lib/armsom || return 1
}

first_boot_link()
{
    local temporary
    temporary=$(mktemp -d "$(dirname "$2")/.armsom-link.XXXXXX") || return 1
    ln -s "$1" "$temporary/link" || return 1
    mv -Tf "$temporary/link" "$2" || return 1
    rmdir "$temporary" || return 1
    sync -f "$(dirname "$2")" || return 1
}

first_boot_fstab_add()
{
    local temporary
    temporary=$(mktemp /etc/fstab.XXXXXX) || return 1
    cp -p /etc/fstab "$temporary" || return 1
    printf '%s\n' "$1" >> "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -f "$temporary" /etc/fstab || return 1
    sync -f /etc || return 1
}

# Selection is read-only and shared with the recovery guard.
first_boot_boot_device()
(
    set -o pipefail
    local root_device root_disk boot_device boot_disk boot_number="" arg cmdline
    local candidates
    root_device=$(findmnt -nro SOURCE -T /) || return 1
    root_device=$(readlink -f "$root_device") || return 1
    [ -b "$root_device" ] || { echo "Cannot resolve running root block device: $root_device" >&2; return 1; }
    [ "$(lsblk -ndo TYPE "$root_device")" = part ] || {
        echo "Unsupported root layout: expected a physical disk partition" >&2; return 1;
    }
    root_disk=$(lsblk -ndo PKNAME "$root_device") || return 1
    [ -n "$root_disk" ] && [ -b "/dev/$root_disk" ] || {
        echo "Cannot identify running root disk" >&2; return 1;
    }
    cmdline=$(cat /proc/cmdline) || return 1
    for arg in $cmdline; do
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
        candidates=$(lsblk -nrpo NAME,PARTLABEL "/dev/$root_disk" | awk '$2 == "boot" { print $1 }') || return 1
        [ -n "$candidates" ] && [ "$(printf '%s\n' "$candidates" | wc -l)" -eq 1 ] || {
            echo "Expected exactly one boot partition on /dev/$root_disk" >&2; return 1;
        }
        boot_device=$candidates
    fi
    boot_device=$(readlink -f "$boot_device") || return 1
    [ -b "$boot_device" ] && [ "$boot_device" != "$root_device" ] || {
        echo "Invalid boot partition: $boot_device" >&2; return 1;
    }
    boot_disk=$(lsblk -ndo PKNAME "$boot_device") || return 1
    [ "$boot_disk" = "$root_disk" ] && [ "$(lsblk -ndo TYPE "$boot_device")" = part ] || {
        echo "Boot partition must belong to the running root disk" >&2; return 1;
    }

    printf '%s\n' "$boot_device"
)

# /boot is selected from the running root filesystem, never by a global UUID.
first_boot_mount_boot()
{
    local boot_device mounted_source mounted_options temporary check_status
    udevadm settle --timeout=30 || return 1
    boot_device=$(first_boot_boot_device) || return 1

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
    echo "[boot-mount] Verified same-disk boot=$boot_device"
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
