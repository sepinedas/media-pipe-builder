#!/usr/bin/env bash
#
# Packages the staged MediaPipe tree produced by build_mediapipe.sh into:
#   1. a Debian package (.deb) installable on a Raspberry Pi Zero 2 W, and
#   2. a plain tarball of the aarch64 C++ libraries / binaries.
#
# Runs on the host runner (needs dpkg-deb + tar). Emits into dist/artifacts/.
set -euxo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"
DIST="${WORKSPACE_DIR}/dist"
STAGING="${DIST}/staging"
VER="$(cat "${DIST}/version.txt")"
DEB_REVISION="${DEB_REVISION:-1}"
OUT="${DIST}/artifacts"
mkdir -p "${OUT}"

PREFIX="opt/mediapipe/${VER}"

# ---------------------------------------------------------------------------
# 1. Tarball of the C++ libraries + binaries.
# ---------------------------------------------------------------------------
TARBALL="${OUT}/mediapipe-${VER}-aarch64-rpi.tar.gz"
tar -C "${STAGING}" -czf "${TARBALL}" "${PREFIX}"
echo "Created ${TARBALL}"

# ---------------------------------------------------------------------------
# 2. Debian package.
# ---------------------------------------------------------------------------
PKG_ROOT="${DIST}/deb"
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/${PREFIX}"
cp -a "${STAGING}/${PREFIX}/." "${PKG_ROOT}/${PREFIX}/"

INSTALLED_KB="$(du -sk "${PKG_ROOT}/opt" | awk '{print $1}')"

mkdir -p "${PKG_ROOT}/DEBIAN"
cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: libmediapipe
Version: ${VER}-${DEB_REVISION}
Section: libs
Priority: optional
Architecture: arm64
Maintainer: media-pipe-builder <noreply@users.noreply.github.com>
Installed-Size: ${INSTALLED_KB}
Depends: libc6 (>= 2.36), libstdc++6, libgcc-s1
Recommends: libopencv-dev, ffmpeg
Homepage: https://github.com/google-ai-edge/mediapipe
Description: MediaPipe ${VER} C++ libraries and CPU tools for Raspberry Pi (aarch64)
 Prebuilt MediaPipe ${VER} for 64-bit Raspberry Pi OS (Bookworm / aarch64).
 Includes the Tasks Vision C++ shared library (libmediapipe_tasks.so),
 MediaPipe headers, graph configurations, TFLite models and CPU example
 binaries (object detection, face detection, hand and pose tracking).
 Tested to run on a Raspberry Pi Zero 2 W and newer 64-bit Pi boards.
EOF

# Post-install: register the library path and expose the example binaries.
cat > "${PKG_ROOT}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
echo "/opt/mediapipe/${VER}/lib" > /etc/ld.so.conf.d/mediapipe.conf
ldconfig
for b in /opt/mediapipe/${VER}/bin/*; do
    if [ -f "\$b" ] && [ -x "\$b" ]; then
        ln -sf "\$b" "/usr/bin/\$(basename "\$b")"
    fi
done
echo "MediaPipe ${VER} installed under /opt/mediapipe/${VER}."
echo "For runtime video I/O install: sudo apt-get install -y libopencv-dev ffmpeg"
exit 0
EOF

cat > "${PKG_ROOT}/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
for b in /opt/mediapipe/${VER}/bin/*; do
    if [ -f "\$b" ] && [ -x "\$b" ]; then
        link="/usr/bin/\$(basename "\$b")"
        [ -L "\$link" ] && rm -f "\$link" || true
    fi
done
exit 0
EOF

cat > "${PKG_ROOT}/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
rm -f /etc/ld.so.conf.d/mediapipe.conf
ldconfig 2>/dev/null || true
exit 0
EOF

chmod 0755 "${PKG_ROOT}/DEBIAN/postinst" "${PKG_ROOT}/DEBIAN/prerm" "${PKG_ROOT}/DEBIAN/postrm"

DEB="${OUT}/libmediapipe_${VER}-${DEB_REVISION}_arm64.deb"
dpkg-deb --root-owner-group --build "${PKG_ROOT}" "${DEB}"
echo "Created ${DEB}"

echo "==> Package metadata"
dpkg-deb --info "${DEB}"
dpkg-deb --contents "${DEB}" | head -n 40

ls -lh "${OUT}"
