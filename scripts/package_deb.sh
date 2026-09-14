#!/usr/bin/env bash
#
# Packages the staged MediaPipe tree produced by build_mediapipe.sh into:
#   1. a Debian package (.deb) installable on a Raspberry Pi 5, and
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
TARBALL="${OUT}/mediapipe-${VER}-aarch64-rpi5.tar.gz"
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

# Runtime dependencies resolved from the shared library's DT_NEEDED entries
# inside the Bookworm build container (see build_mediapipe.sh). Without these
# the package installs but libmediapipe_tasks.so fails to load, because it
# links OpenCV dynamically.
RESOLVED_DEPENDS="$(tr -d '\n' < "${DIST}/depends.txt" 2>/dev/null || true)"
if [ -n "${RESOLVED_DEPENDS}" ]; then
    DEPENDS="libc6 (>= 2.36), ${RESOLVED_DEPENDS}"
else
    echo "WARNING: dist/depends.txt is missing or empty; falling back to a" >&2
    echo "         minimal Depends line, which under-declares OpenCV." >&2
    DEPENDS="libc6 (>= 2.36), libstdc++6, libgcc-s1"
fi

mkdir -p "${PKG_ROOT}/DEBIAN"
cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: libmediapipe
Version: ${VER}-${DEB_REVISION}
Section: libs
Priority: optional
Architecture: arm64
Maintainer: media-pipe-builder <noreply@users.noreply.github.com>
Installed-Size: ${INSTALLED_KB}
Depends: ${DEPENDS}
Recommends: libopencv-dev, ffmpeg
Homepage: https://github.com/google-ai-edge/mediapipe
Description: MediaPipe ${VER} C++ libraries and CPU tools for Raspberry Pi 5 (aarch64)
 Prebuilt MediaPipe ${VER} for 64-bit Raspberry Pi OS (Bookworm / aarch64).
 Includes the Tasks Vision C++ shared library (libmediapipe_tasks.so),
 MediaPipe headers, graph configurations, TFLite models and CPU example
 binaries (object detection, face detection, hand and pose tracking).
 Compiled for the Pi 5's Cortex-A76 (-mcpu=cortex-a76), so it will NOT run on
 a Pi 4, Pi 3 or Zero 2 W -- those fault with SIGILL.
EOF

# Where a multiarch system looks for .pc files, and the version-independent
# path downstream code can hardcode instead of chasing /opt/mediapipe/<ver>.
PKGCONFIG_LINK="/usr/lib/aarch64-linux-gnu/pkgconfig/mediapipe.pc"
CURRENT_LINK="/opt/mediapipe/current"

# Post-install: register the library path, expose the example binaries, and
# make the package discoverable by pkg-config and by a stable path.
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
# Stable path to the newest install, so applications (and their model lookups)
# do not have to know the version number.
ln -sfn "/opt/mediapipe/${VER}" "${CURRENT_LINK}"
# Expose the .pc so \`pkg-config --cflags --libs mediapipe\` just works.
if [ -f "/opt/mediapipe/${VER}/lib/pkgconfig/mediapipe.pc" ]; then
    mkdir -p "\$(dirname "${PKGCONFIG_LINK}")"
    ln -sf "/opt/mediapipe/${VER}/lib/pkgconfig/mediapipe.pc" "${PKGCONFIG_LINK}"
fi
echo "MediaPipe ${VER} installed under /opt/mediapipe/${VER} (also ${CURRENT_LINK})."
echo "Build against it with: pkg-config --cflags --libs mediapipe  (needs C++20)"
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
# Only drop the shared links if they still point at *this* version; a newer
# package installed alongside will have already repointed them at itself.
if [ "\$(readlink "${CURRENT_LINK}" 2>/dev/null)" = "/opt/mediapipe/${VER}" ]; then
    rm -f "${CURRENT_LINK}"
fi
pc_target="/opt/mediapipe/${VER}/lib/pkgconfig/mediapipe.pc"
if [ "\$(readlink "${PKGCONFIG_LINK}" 2>/dev/null)" = "\$pc_target" ]; then
    rm -f "${PKGCONFIG_LINK}"
fi
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
dpkg-deb --contents "${DEB}" | head -n 40 || true

ls -lh "${OUT}"
