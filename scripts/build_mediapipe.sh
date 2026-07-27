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
    clang \
    lld \
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

# MediaPipe's api3 framework (C++20 class-type NTTPs with deleted copy ctors) is
# developed and tested against Clang; GCC rejects that pattern. Build with Clang.
export CC=clang
export CXX=clang++
echo "==> Using compiler: $(clang --version | head -n1)"

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
    --repo_env=CC=clang
    --repo_env=CXX=clang++
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

# --- Example binaries -----------------------------------------------------
# NOTE: we intentionally do NOT copy the Bazel *.runfiles trees. They contain
# self-referential symlinks (<bin>.runfiles/<bin>.runfiles -> .) that turn a
# dereferencing copy into an unbounded recursion. Instead we ship the binaries
# plus a structured model/graph tree below.
copy_example() {
    local label_dir="$1" name="$2"
    cp -L "bazel-bin/mediapipe/examples/desktop/${label_dir}/${name}" "${PREFIX}/bin/${name}"
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

# --- Models / assets ------------------------------------------------------
# Structured tree from the MediaPipe source (preserves the mediapipe/... paths
# that graphs reference at runtime). Run examples with this as the CWD.
DATA="${PREFIX}/share/mediapipe/data"
( cd "${SRC}"
  find mediapipe/modules mediapipe/models -type f \
       \( -name '*.tflite' -o -name '*.binarypb' -o -name '*.txt' \) -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
      install -D "$f" "${DATA}/${f}"
  done )
# Models fetched by Bazel (e.g. ssdlite_object_detection) live under external/.
# Use a plain (non-symlink-following) find on the real external dir to avoid
# the runfiles symlink cycles. Place them flat in models/ (convenience) and in
# data/mediapipe/models/ (the path the desktop graphs expect at runtime).
if [ -d "${BAZEL_OUTPUT_BASE}/external" ]; then
    mkdir -p "${DATA}/mediapipe/models"
    find "${BAZEL_OUTPUT_BASE}/external" -type f -name '*.tflite' -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        cp -n "$f" "${PREFIX}/share/mediapipe/models/" 2>/dev/null || true
        cp -n "$f" "${DATA}/mediapipe/models/" 2>/dev/null || true
    done
fi

# --- Headers: MediaPipe sources + generated protobuf headers --------------
echo "==> Exporting headers"
INC="${PREFIX}/include"
# Source headers.
find mediapipe -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) \
    -print0 | while IFS= read -r -d '' f; do
    install -D "$f" "${INC}/${f}"
done
# Generated headers (from the real bazel-out dir; prune runfiles trees so we
# never descend into their symlink cycles). MediaPipe's public headers include
# both generated protobuf headers (*.pb.h) and flatbuffers-generated schema
# headers (*_generated.h, e.g. mediapipe/tasks/metadata/metadata_schema_generated.h),
# neither of which exists in the source checkout.
BIN_REAL="$(readlink -f bazel-bin)"
find "${BIN_REAL}/mediapipe" -type d -name '*.runfiles' -prune -o \
     -type f \( -name '*.pb.h' -o -name '*_generated.h' \) -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    rel="mediapipe/${f#"${BIN_REAL}"/mediapipe/}"
    install -D "$f" "${INC}/${rel}"
done

# --- Third-party dependency headers ---------------------------------------
# MediaPipe's *public* C++ headers #include their pinned dependencies, so a
# downstream program that includes a Tasks header pulls them in transitively:
#   face_landmarker.h -> framework/formats/image.h        -> absl/...
#                     -> framework/formats/matrix.h        -> Eigen/Core
#                     -> framework/port/logging.h          -> glog/logging.h
#                     -> ...generated *.pb.h               -> google/protobuf/...
# These live in Bazel's external tree (some checked in, some generated into
# bazel-bin), NOT under mediapipe/. Export them at the *exact* versions the
# shared library was built against -- this MediaPipe pins protobuf 5.28 and a
# 2023 Abseil, far newer than Debian Bookworm's, so downstream code cannot fall
# back to system copies without API/ABI drift against the symbols baked into
# libmediapipe_tasks.so. Bundling them makes include/ self-contained.
echo "==> Exporting third-party dependency headers"
EXT_SRC="${BAZEL_OUTPUT_BASE}/external"
EXT_GEN="${BIN_REAL}/external"

# Copy a dependency's header namespace <top> (e.g. "absl") into include/,
# searching both the checked-in and generated external trees and merging them
# (generated headers such as glog/logging.h overlay the source tree). $1 is a
# probe header used to locate each include root; $2 is the top-level dir to copy.
export_dep() {
    local probe="$1" top="$2" base hit root found=0
    for base in "${EXT_SRC}" "${EXT_GEN}"; do
        [ -d "${base}" ] || continue
        while IFS= read -r hit; do
            [ -n "${hit}" ] || continue
            root="${hit%/"${probe}"}"
            [ -d "${root}/${top}" ] || continue
            # rsync only creates the final dest component; pre-create parents so
            # a nested namespace (e.g. tensorflow/lite) doesn't fail on mkdir.
            mkdir -p "${INC}/${top}"
            rsync -a --prune-empty-dirs \
                --include='*/' \
                --include='*.h' --include='*.hpp' --include='*.hh' \
                --include='*.hxx' --include='*.inc' --include='*.ipp' \
                --include='*.proto' --exclude='*' \
                "${root}/${top}/" "${INC}/${top}/"
            found=1
        done < <(find "${base}" -maxdepth 8 -path "*/${probe}" 2>/dev/null || true)
    done
    if [ "${found}" = 1 ]; then echo "   + ${top}"; else
        echo "   ! ${top} headers not found (probe ${probe})"; fi
}

export_dep "absl/base/config.h"        "absl"
export_dep "google/protobuf/port.h"    "google"
export_dep "flatbuffers/flatbuffers.h" "flatbuffers"
export_dep "glog/logging.h"            "glog"
export_dep "gflags/gflags.h"           "gflags"
# MediaPipe's Tasks headers pull in TensorFlow Lite: base_options.h ->
# mediapipe_builtin_op_resolver.h -> tensorflow/lite/kernels/register.h, whose
# transitive closure reaches across several tensorflow/ subtrees (e.g. the TFLite
# interpreter headers include tensorflow/compiler/mlir/lite/...). Export the
# whole tensorflow/ header tree so every tensorflow/... include resolves.
export_dep "tensorflow/lite/kernels/register.h" "tensorflow"

# Eigen headers are extensionless (Eigen/Core, Eigen/Dense), so copy the trees
# wholesale rather than filtering by suffix.
for base in "${EXT_SRC}" "${EXT_GEN}"; do
    eh="$(find "${base}" -maxdepth 8 -path "*/Eigen/Core" -print -quit 2>/dev/null || true)"
    if [ -n "${eh}" ]; then
        er="${eh%/Eigen/Core}"
        echo "   + Eigen"
        rsync -a "${er}/Eigen" "${INC}/"
        [ -d "${er}/unsupported" ] && rsync -a "${er}/unsupported" "${INC}/"
        break
    fi
done

# utf8_range (a protobuf 5.x dependency) ships flat headers included without a
# namespace prefix; drop them at the include root if present.
for base in "${EXT_SRC}" "${EXT_GEN}"; do
    uh="$(find "${base}" -maxdepth 8 -name 'utf8_validity.h' -print -quit 2>/dev/null || true)"
    if [ -n "${uh}" ]; then
        echo "   + utf8_range"
        find "$(dirname "${uh}")" -maxdepth 1 -name '*.h' -exec cp -n {} "${INC}/" \;
        break
    fi
done

# --- Materialise symlinked headers into real files ------------------------
# The dependency headers above were rsync'd out of Bazel's external tree, whose
# _virtual_includes layout is a forest of symlinks pointing back into the build
# tree. Copied with `rsync -a`, those headers land in include/ as symlinks:
#   * they would dangle the moment the tarball/.deb is extracted on the target
#     device (the build tree they point at doesn't exist there), and
#   * `find -type f` (used below to patch glog) silently skips them.
# Replace every symlink under include/ with a copy of its referent so the
# packaged tree is genuine, self-contained files.
echo "==> Materialising symlinked headers into real files"
find "${INC}" -type l | while IFS= read -r link; do
    tgt="$(readlink -f "${link}" 2>/dev/null || true)"
    if [ -n "${tgt}" ] && [ -f "${tgt}" ]; then
        cp -f --remove-destination "${tgt}" "${link}"
    fi
done

# --- glog 0.6.0 self-containment fix (export macros) ----------------------
# glog's *Bazel* build (unlike its CMake build) never generates glog/export.h
# and leaves the `#include <glog/export.h>` compiled out of its public headers
# (@ac_cv_have_glog_export@ is hardcoded to 0). Instead it defines the
# GLOG_EXPORT / GLOG_NO_EXPORT / GLOG_DEPRECATED macros through the glog
# cc_library's `defines` attribute, i.e. as -D flags Bazel injects into every
# glog consumer at compile time. A downstream program that compiles against the
# packaged headers outside Bazel has neither a generated export.h nor those -D
# flags, so glog/logging.h fails with "GLOG_EXPORT undefined". Prepend guarded
# definitions of these macros (matching glog's non-Windows `defines`) to the top
# of every exported glog header so GLOG_EXPORT is always defined before use,
# independent of the generated headers' include wiring. A matching glog/export.h
# is written too, for any header that includes it directly.
if [ -d "${INC}/glog" ]; then
    echo "   + glog export macros (Bazel supplies these via -D, not glog/export.h)"
    GLOG_MACROS="$(mktemp)"
    cat > "${GLOG_MACROS}" <<'EOF'
/* Injected by the MediaPipe aarch64 packaging. glog 0.6.0's Bazel build defines
   these macros via compiler -D flags instead of glog/export.h, so code building
   against the bundled headers outside Bazel would otherwise see GLOG_EXPORT
   undefined. Definitions match glog's non-Windows cc_library `defines`. */
#ifndef GLOG_EXPORT
#define GLOG_EXPORT __attribute__((visibility("default")))
#endif
#ifndef GLOG_NO_EXPORT
#define GLOG_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#ifndef GLOG_DEPRECATED
#define GLOG_DEPRECATED __attribute__((deprecated))
#endif
EOF
    find -L "${INC}/glog" -type f -name '*.h' -print0 | while IFS= read -r -d '' gh; do
        cat "${GLOG_MACROS}" "${gh}" > "${gh}.tmp" && mv "${gh}.tmp" "${gh}"
    done
    # Provide glog/export.h too (Bazel omits it), in case a header includes it.
    {
        echo "#ifndef GLOG_EXPORT_H"
        echo "#define GLOG_EXPORT_H"
        cat "${GLOG_MACROS}"
        echo "#endif  // GLOG_EXPORT_H"
    } > "${INC}/glog/export.h"
    rm -f "${GLOG_MACROS}"
fi

# --- Verify the exported include tree is self-contained -------------------
# Compile (syntax-only) a real Tasks program against ONLY the packaged headers
# (plus OpenCV). If any transitive dependency header is missing from include/,
# this fails the build here -- with the exact missing-header error -- instead of
# shipping a .deb that cannot be compiled against on the device.
echo "==> Verifying the exported headers compile a Face Landmarker program"
CHECK_SRC="$(mktemp --suffix=.cc)"
cat > "${CHECK_SRC}" <<'EOF'
#include "mediapipe/tasks/cc/vision/face_landmarker/face_landmarker.h"
#include "mediapipe/tasks/cc/vision/face_landmarker/face_landmarker_result.h"
#include "mediapipe/framework/formats/image.h"
#include "mediapipe/framework/formats/image_frame_opencv.h"
int main() { return 0; }
EOF
if clang++ -std=c++20 -fsyntax-only -DMEDIAPIPE_DISABLE_GPU=1 \
       -I"${INC}" $(pkg-config --cflags opencv4 2>/dev/null) "${CHECK_SRC}"; then
    echo "   self-check passed: include/ is self-contained"
else
    echo "!! header self-check FAILED: the exported include/ tree is missing one" >&2
    echo "!! or more transitive dependency headers (see the compiler errors above)." >&2
    rm -f "${CHECK_SRC}"
    exit 1
fi
rm -f "${CHECK_SRC}"

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
