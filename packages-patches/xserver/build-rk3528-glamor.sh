#!/bin/bash
# Native arm64 build: pass the upstream 21.1.7 tarball and output directory.
# Requires meson, ninja, gcc, xserver-xorg-dev and its development dependencies.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "Usage: $0 xorg-server_21.1.7.orig.tar.gz output-dir" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = arm64 ] || { echo 'Build this package on arm64' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
patch_dir="$script_dir/21.1.7"
tarball=$(realpath -- "$1")
mkdir -p -- "$2"
output_dir=$(realpath -- "$2")
echo "1a9005f47c7ea83645a977581324439628a32c4426303e5a4b9c2d6615becfbf  $tarball" | sha256sum -c -
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rk3528-glamor.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
tar -xzf "$tarball" -C "$work_dir"
cd "$work_dir/xorg-server-21.1.7"
for patch_file in "$patch_dir"/*.patch "$script_dir/utgard-450"/*.patch; do
    patch -p1 --batch --forward --no-backup-if-mismatch < "$patch_file"
done
meson setup build --prefix=/usr --libdir=lib -Dmodule_dir=/usr/lib/xorg/modules \
    -Dxorg=true -Dglamor=true -Dxephyr=false -Dxnest=false -Dxvfb=false \
    -Dxwin=false -Dxquartz=false -Ddocs=false -Ddevel-docs=false \
    -Dsystemd_logind=true -Dbuildtype=debugoptimized
ninja -C build -j"${JOBS:-3}" hw/xfree86/glamor_egl/libglamoregl.so
package_dir="$work_dir/package"
install -D -s -m 755 build/hw/xfree86/glamor_egl/libglamoregl.so \
    "$package_dir/usr/lib/armsom/rk3528/xorg/modules/libglamoregl.so"
# Keep existing Sige1 Xorg configurations working on upgrade.
mkdir -p "$package_dir/usr/lib/armsom/sige1/xorg/modules"
ln -s ../../../rk3528/xorg/modules/libglamoregl.so \
    "$package_dir/usr/lib/armsom/sige1/xorg/modules/libglamoregl.so"
mkdir -p "$package_dir/DEBIAN" "$package_dir/etc/X11/xorg.conf.d"
cat > "$package_dir/DEBIAN/control" <<'EOF'
Package: armsom-rk3528-glamor
Version: 1.0
Architecture: arm64
Maintainer: ArmSoM
Depends: xserver-xorg-core (= 2:21.1.7-3+deb12u2) | xserver-xorg-core (= 2:21.1.7-3-ubuntu22.04), libmali-utgard-450-r7p0-x11-gbm
Conflicts: armsom-sige1-xorg-fix
Replaces: armsom-sige1-xorg-fix
Section: x11
Priority: optional
Description: Rockchip RK3528 Mali-450 glamor compatibility fix
 Avoid unsupported core GL debug callbacks while retaining GPU acceleration.
EOF
cat > "$package_dir/etc/X11/xorg.conf.d/01-sige1-glamor.conf" <<'EOF'
Section "Files"
    ModulePath "/usr/lib/armsom/rk3528/xorg/modules"
    ModulePath "/usr/lib/xorg/modules"
EndSection
EOF
echo /etc/X11/xorg.conf.d/01-sige1-glamor.conf > "$package_dir/DEBIAN/conffiles"
dpkg-deb --root-owner-group -Zxz --build "$package_dir" \
    "$output_dir/armsom-rk3528-glamor_1.0_arm64.deb"
