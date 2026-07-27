#!/usr/bin/env bash
#
# Builds MediaPipe C++ artifacts for aarch64 (64-bit Raspberry Pi OS).
#
# Runs inside a debian:bookworm arm64 container so the produced binaries and
# shared libraries link against glibc 2.36 -- matching 64-bit Raspberry Pi OS
# (Bookworm), which keeps them runnable on a Raspberry Pi Zero 2 W and newer.
#
# Inputs (environment):
#   MEDIAPIPE_VERSION  git tag to build, e.g. "v0.10.35"   (required)
#   WORKSPACE_DIR      repo checkout mounted in the container (default /workspace)
#   BUILD_ROOT         scratch dir on the large disk         (default /mnt/mpbuild)
#
# Output:
#   ${WORKSPACE_DIR}/dist/staging/opt/mediapipe/<ver>/{lib,bin,include,share}
#   ${WORKSPACE_DIR}/dist/version.txt
set -euxo pipefail

MEDIAPIPE_VERSION="${MEDIAPIPE_VERSION:?MEDIAPIPE_VERSION must be set (e.g. v0.10.35)}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
BUILD_ROOT="${BUILD_ROOT:-/mnt/mpbuild}"

# Normalised version without the leading "v".
VER="${MEDIAPIPE_VERSION#v}"

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

echo "==> Installing build dependencies"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    unzip \
    wget \
    zip \
    pkg-config \
    zlib1g-dev \
    python3 \
    python3-dev \
    python3-pip \
    python3-numpy \
    python-is-python3 \
    default-jdk \
    libopencv-dev \
    libavformat-dev \
    libavcodec-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    libgl1-mesa-dev \
    mesa-common-dev \
    file \
    patchelf \
    rsync
update-ca-certificates || true

echo "==> Installing Bazelisk (drives the Bazel version pinned in .bazelversion)"
BAZELISK_VERSION="v1.25.0"
curl -fsSL -o /usr/local/bin/bazel \
    "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-arm64"
chmod +x /usr/local/bin/bazel
bazel version || true

echo "==> Fetching MediaPipe ${MEDIAPIPE_VERSION}"
SRC="${BUILD_ROOT}/mediapipe"
BAZEL_OUTPUT_BASE="${BUILD_ROOT}/bazel"
mkdir -p "${BUILD_ROOT}"
rm -rf "${SRC}"
git clone --depth 1 --branch "${MEDIAPIPE_VERSION}" \
    https://github.com/google-ai-edge/mediapipe.git "${SRC}"

echo "==> Applying aarch64 overlays"
# Enable the aarch64 OpenCV header/include layout.
cp "${WORKSPACE_DIR}/overlay/opencv_linux.BUILD" "${SRC}/third_party/opencv_linux.BUILD"
# Inject the shared-library target that bundles the Tasks Vision C++ API.
mkdir -p "${SRC}/libmp"
cp "${WORKSPACE_DIR}/overlay/libmp.BUILD" "${SRC}/libmp/BUILD"

cd "${SRC}"

# CPU-only build flags. MEDIAPIPE_DISABLE_GPU=1 avoids EGL/GLES dependencies,
# which are neither present nor needed for headless inference on the Pi.
#
# Note: MediaPipe >= 0.10.3x builds globally with C++20 (its api3 node framework
# uses `consteval` and class-type non-type template parameters). We deliberately
# do NOT pass -std here so MediaPipe's own C++20 standard is honoured; forcing
# c++17 breaks the api3 calculators.
COMMON_FLAGS=(
    -c opt
    --define MEDIAPIPE_DISABLE_GPU=1
    --linkopt=-s
    --jobs=HOST_CPUS
    --local_ram_resources=HOST_RAM*0.6
    --verbose_failures
)

EXAMPLE_TARGETS=(
    //mediapipe/examples/desktop/object_detection:object_detection_cpu
    //mediapipe/examples/desktop/face_detection:face_detection_cpu
    //mediapipe/examples/desktop/hand_tracking:hand_tracking_cpu
    //mediapipe/examples/desktop/pose_tracking:pose_tracking_cpu
)
LIB_TARGET="//libmp:libmediapipe_tasks.so"

echo "==> Building MediaPipe example CPU binaries"
bazel --output_base="${BAZEL_OUTPUT_BASE}" build "${COMMON_FLAGS[@]}" "${EXAMPLE_TARGETS[@]}"

echo "==> Building MediaPipe Tasks Vision shared library"
bazel --output_base="${BAZEL_OUTPUT_BASE}" build "${COMMON_FLAGS[@]}" "${LIB_TARGET}"

echo "==> Collecting artifacts"
PREFIX="${WORKSPACE_DIR}/dist/staging/opt/mediapipe/${VER}"
rm -rf "${WORKSPACE_DIR}/dist"
mkdir -p "${PREFIX}/lib" "${PREFIX}/bin" "${PREFIX}/include" \
         "${PREFIX}/share/mediapipe/graphs" "${PREFIX}/share/mediapipe/models"

# --- Shared library -------------------------------------------------------
cp -L "bazel-bin/libmp/libmediapipe_tasks.so" "${PREFIX}/lib/libmediapipe_tasks.so"
patchelf --set-soname libmediapipe_tasks.so "${PREFIX}/lib/libmediapipe_tasks.so" || true

# --- Example binaries + their runfiles (data/models) ----------------------
copy_example() {
    local label_dir="$1" name="$2"
    local bin="bazel-bin/mediapipe/examples/desktop/${label_dir}/${name}"
    cp -L "${bin}" "${PREFIX}/bin/${name}"
    if [ -d "${bin}.runfiles" ]; then
        # Dereference symlinks so the runfiles tree is self-contained.
        cp -RL "${bin}.runfiles" "${PREFIX}/bin/${name}.runfiles" 2>/dev/null || \
            cp -R "${bin}.runfiles" "${PREFIX}/bin/${name}.runfiles"
    fi
}
copy_example object_detection object_detection_cpu
copy_example face_detection   face_detection_cpu
copy_example hand_tracking    hand_tracking_cpu
copy_example pose_tracking    pose_tracking_cpu

# --- Graph configs --------------------------------------------------------
for g in \
    mediapipe/graphs/object_detection/object_detection_desktop_live.pbtxt \
    mediapipe/graphs/face_detection/face_detection_desktop_live.pbtxt \
    mediapipe/graphs/hand_tracking/hand_tracking_desktop_live.pbtxt \
    mediapipe/graphs/pose_tracking/pose_tracking_desktop_live.pbtxt ; do
    [ -f "$g" ] && cp "$g" "${PREFIX}/share/mediapipe/graphs/" || true
done

# --- Models (.tflite) shipped in-tree or fetched into runfiles ------------
find mediapipe/models -name '*.tflite' -exec cp {} "${PREFIX}/share/mediapipe/models/" \; 2>/dev/null || true
find -L bazel-bin -name '*.tflite' -exec cp -n {} "${PREFIX}/share/mediapipe/models/" \; 2>/dev/null || true

# --- Headers: MediaPipe sources + generated protobuf headers --------------
echo "==> Exporting headers"
INC="${PREFIX}/include"
# Source headers.
find mediapipe -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) \
    -print0 | while IFS= read -r -d '' f; do
    install -D "$f" "${INC}/${f}"
done
# Generated protobuf headers.
find -L bazel-bin/mediapipe -type f -name '*.pb.h' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    rel="${f#bazel-bin/}"
    install -D "$f" "${INC}/${rel}"
done

# --- Docs -----------------------------------------------------------------
cp LICENSE "${PREFIX}/share/mediapipe/LICENSE" 2>/dev/null || true
cat > "${PREFIX}/share/mediapipe/BUILD_INFO.txt" <<EOF
MediaPipe version : ${MEDIAPIPE_VERSION}
Target            : aarch64 (arm64) / 64-bit Raspberry Pi OS (Bookworm, glibc 2.36)
Built with        : $(bazel version 2>/dev/null | head -n1 || echo bazel)
GPU               : disabled (MEDIAPIPE_DISABLE_GPU=1, CPU/TFLite inference)
EOF

echo "${VER}" > "${WORKSPACE_DIR}/dist/version.txt"

echo "==> Fixing ownership so host tooling can read the staging tree"
chown -R "$(stat -c '%u:%g' "${WORKSPACE_DIR}")" "${WORKSPACE_DIR}/dist" || true

echo "==> Done. Staged tree:"
du -sh "${PREFIX}" || true
find "${PREFIX}" -maxdepth 3 -type f | head -n 60 || true
