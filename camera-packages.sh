# Select the Debian camera packages and identify their contents for rootfs cache checks.
select_camera_packages()
{
    local soc=$1 arch=$2 target=$3 policy=${RK_DEBIAN_CAMERA:-auto}
    local family pkg sums
    local camera_dir="packages/$arch/camera"
    local -a packages matches
    camera_debs=()
    camera_key=
    case "$policy" in
        auto|0|1) ;;
        *) echo "Invalid RK_DEBIAN_CAMERA=$policy (expected auto, 1, or 0)" >&2; return 1 ;;
    esac
    case "$soc/$arch" in
        rk3576/arm64) family=RK3576 ;;
        rk3588/arm64|rk3588s/arm64) family=RK3588 ;;
        *)
            [[ "$policy" != 1 ]] && return 0
            echo "RK_DEBIAN_CAMERA=1 requires RK3576 or RK3588/RK3588S arm64; selected $soc $arch" >&2
            return 1 ;;
    esac
    case "$target/$policy" in
        */0) camera_key=off; return 0 ;;
        server/auto|server/1) packages=(armsom-camera) ;;
        gnome/*|xfce/*|lxde/*) packages=(armsom-camera armsom-camera-desktop) ;;
        *) echo "Unsupported camera image target: $target" >&2; return 1 ;;
    esac
    for pkg in "${packages[@]}"; do
        matches=("$camera_dir/$family/${pkg}_"*"_${arch}.deb")
        if [[ ${#matches[@]} != 1 || ! -f "${matches[0]}" ]]; then
            echo "Expected one $camera_dir/$family/${pkg}_*_${arch}.deb" >&2
            return 1
        fi
        camera_debs+=("$family/${matches[0]##*/}")
    done
    sums=$(cd "$camera_dir" && sha256sum -- "${camera_debs[@]}") || return 1
    camera_key=$(printf '%s\n' "$sums" | sha256sum) || return 1
    camera_key=${camera_key%% *}
}

# Check the contents of an existing ext4 image without mounting or modifying it.
camera_cache_matches()
{
    local image=$1 stored info
    stored=$(debugfs -R 'cat /var/lib/armsom/camera-packages.sha256' "$image" 2>/dev/null) || return 1
    if [[ "$camera_key" == off && -z "$stored" ]]; then
        # Older images have no fingerprint but may already include the camera packages.
        info=$(debugfs -R 'stat /var/lib/dpkg/info/armsom-camera.list' "$image" 2>/dev/null) || return 1
        [[ -z "$info" ]]
    else
        [[ "$stored" == "$camera_key" ]]
    fi
}
