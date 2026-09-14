#!/usr/bin/env bash
#
# Builds MediaPipe C++ artifacts for the Raspberry Pi 5 (aarch64).
#
# Runs inside a Debian arm64 container whose release MUST match the target
# Pi's OS -- Raspberry Pi OS for the Pi 5 is Debian 13 (trixie). Two things are
# pinned by that choice and cannot be papered over afterwards:
#   * glibc, so the binaries load at all, and
#   * OpenCV, which the shared library links *by soname*. Trixie has OpenCV
#     4.10 (libopencv_core.so.410); bookworm has 4.6 (.so.406). A library built
#     on the wrong one cannot be loaded on the target, and installing both
#     OpenCVs is not a workaround: cv::Mat crosses the library boundary (see
#     formats::MatView), so two OpenCV ABIs in one process is undefined
#     behaviour.
# Code generation additionally targets the Pi 5's Cortex-A76 (see TARGET_MCPU
# below), so the artifacts are NOT portable to older Pi boards either.
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
# Inject the shared-library target that bundles the Tasks Vision C++ API, plus
# the force-export source it compiles in (keeps the public factory symbols in
# the .so so downstream code can link them).
mkdir -p "${SRC}/libmp"
cp "${WORKSPACE_DIR}/overlay/libmp.BUILD" "${SRC}/libmp/BUILD"
cp "${WORKSPACE_DIR}/overlay/force_export.cc" "${SRC}/libmp/force_export.cc"

cd "${SRC}"

# CPU-only build flags. MEDIAPIPE_DISABLE_GPU=1 avoids EGL/GLES dependencies,
# which are neither present nor needed for headless inference on the Pi.
#
# Note: MediaPipe >= 0.10.3x builds globally with C++20 (its api3 node framework
# uses `consteval` and class-type non-type template parameters). We deliberately
# do NOT pass -std here so MediaPipe's own C++20 standard is honoured; forcing
# c++17 breaks the api3 calculators.
#
# -mcpu=cortex-a76 targets the Raspberry Pi 5's BCM2712. It raises the assumed
# baseline from generic ARMv8-A to the A76's ARMv8.2-A -- dot product, FP16 and
# LSE atomics -- which is exactly what the quantised TFLite kernels underneath
# the Tasks API want. It is applied with --copt (target configuration) and not
# --host_copt, so Bazel's own build tools stay portable on the runner.
#
# This makes the artifacts Pi 5 only: they will SIGILL on a Pi 4, Pi 3 or
# Zero 2 W (Cortex-A72/A53). That is deliberate -- see the README.
TARGET_MCPU="${TARGET_MCPU:-cortex-a76}"

# MediaPipe pulls in TensorFlow, whose hermetic-Python setup picks the *system*
# interpreter unless told otherwise and then wants a matching
# requirements_lock.txt. It only ships locks for 3.9 - 3.12, so on Debian
# trixie (Python 3.13) the build dies before compiling anything with:
#
#   Could not find requirements_lock.txt file matching specified Python version.
#   Specified python version: 3.13
#
# Pin it explicitly. 3.11 is chosen because that is what bookworm's system
# Python was, i.e. exactly what every previously-successful build of this
# pipeline resolved to -- so moving the container to trixie does not quietly
# change the Python toolchain at the same time. The interpreter is hermetic
# (Bazel fetches it), so this is independent of what the container has.
HERMETIC_PYTHON_VERSION="${HERMETIC_PYTHON_VERSION:-3.11}"

COMMON_FLAGS=(
    -c opt
    --define MEDIAPIPE_DISABLE_GPU=1
    --repo_env=CC=clang
    --repo_env=CXX=clang++
    --repo_env=HERMETIC_PYTHON_VERSION="${HERMETIC_PYTHON_VERSION}"
    --copt=-mcpu="${TARGET_MCPU}"
    --copt=-O3
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

# --- Runtime package dependencies -----------------------------------------
# libmediapipe_tasks.so links OpenCV (and friends) *dynamically* -- see
# overlay/opencv_linux.BUILD -- so a .deb that only declares libc6/libstdc++6
# installs cleanly and then fails to load the library at runtime. Resolve the
# real dependencies here, inside the build container, where dpkg can map
# each DT_NEEDED SONAME back to the package that ships it. Doing this on the
# host runner would resolve against the runner's distro instead.
# The OpenCV packages this resolves to are release-specific -- bookworm's
# libopencv-core406 versus trixie's libopencv-core410 -- which is exactly the
# point: declaring them makes apt refuse the package on the wrong Debian
# release instead of letting it install and then fail to load.
echo "==> Resolving runtime package dependencies"
{
    readelf -d "${PREFIX}/lib/libmediapipe_tasks.so" |
        sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
        while IFS= read -r so; do
            pkg="$(dpkg -S "${so}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
            # libc6 is re-emitted below with a minimum-version constraint.
            if [ -n "${pkg}" ] && [ "${pkg}" != "libc6" ]; then echo "${pkg}"; fi
        done | sort -u
    # Pin glibc to whatever this container has rather than a hardcoded number,
    # so the constraint tracks the suite the package was actually built on.
    LIBC_VERSION="$(dpkg-query -W -f='${Version}' libc6 2>/dev/null | cut -d- -f1 || true)"
    if [ -n "${LIBC_VERSION}" ]; then
        echo "libc6 (>= ${LIBC_VERSION})"
    else
        echo "libc6"
    fi
# NB: `paste -sd', '` would be wrong -- -d takes a *list* of delimiters and
# cycles through them, so four packages come out as "a,b c,d" and dpkg-deb
# rejects the field. Join on commas only, then space them out for readability.
} | paste -sd, - | sed 's/,/, /g' > "${WORKSPACE_DIR}/dist/depends.txt"
echo "   depends: $(cat "${WORKSPACE_DIR}/dist/depends.txt")"

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

# --- Tasks model bundles --------------------------------------------------
# The Tasks Vision C++ API (FaceLandmarker and friends) is driven by *.task
# bundles. Unlike the graph-era .tflite files collected above these are NOT in
# the MediaPipe source tree -- Google publishes them separately -- so a package
# without them ships an API with nothing to run. Fetch them into models/ so a
# downstream app has a model to point at out of the box.
echo "==> Downloading Tasks model bundles"
MODEL_BASE="https://storage.googleapis.com/mediapipe-models"
download_model() {
    local url="$1" name="$2" dest="${PREFIX}/share/mediapipe/models/$2"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}"; then
        echo "!! failed to download ${name} from ${url}" >&2
        return 1
    fi
    echo "   + ${name} ($(du -h "${dest}" | cut -f1))"
}
# face_landmarker.task carries the face detector, the 478-point mesh *and* the
# blendshape head. The blendshape head is what FaceLandmarkerOptions'
# output_face_blendshapes needs: with a bundle that lacks it, Create() fails
# outright when blendshapes are requested.
download_model \
    "${MODEL_BASE}/face_landmarker/face_landmarker/float16/1/face_landmarker.task" \
    "face_landmarker.task"

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
# 2023 Abseil, far newer than Debian's own, so downstream code cannot fall
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

# --- pkg-config -----------------------------------------------------------
# Downstream builds should not have to hardcode the versioned install path, nor
# remember that this library is CPU-only. Ship a .pc that says exactly how the
# package wants to be consumed; package_deb.sh links it into the system
# pkg-config search path at install time.
#
# Note the C++ standard is deliberately NOT in Cflags: MediaPipe's headers need
# C++20, but a `-std=` coming from pkg-config would be overridden by whatever
# the consumer's build system appends, so it belongs in the consumer's own
# settings (CMake's CXX_STANDARD, -std=c++20 by hand). The README says so.
echo "==> Writing pkg-config file"
mkdir -p "${PREFIX}/lib/pkgconfig"
cat > "${PREFIX}/lib/pkgconfig/mediapipe.pc" <<EOF
prefix=/opt/mediapipe/${VER}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
datadir=\${prefix}/share/mediapipe
modeldir=\${datadir}/models

Name: mediapipe
Description: MediaPipe ${MEDIAPIPE_VERSION} Tasks Vision C++ API (CPU/TFLite, aarch64)
URL: https://github.com/google-ai-edge/mediapipe
Version: ${VER}
Requires: opencv4
Cflags: -I\${includedir} -DMEDIAPIPE_DISABLE_GPU=1
Libs: -L\${libdir} -lmediapipe_tasks
EOF

# --- Verify the package compiles, links AND runs a real Tasks program -----
# Build a program that does everything a downstream application does -- wrap a
# cv::Mat as a mediapipe::Image, create a FaceLandmarker (blendshapes on) from
# the packaged model bundle and run DetectForVideo -- against ONLY the packaged
# include/ + lib/ (plus OpenCV), then actually execute it. This catches four
# classes of packaging bug before a .deb ships:
#   * a missing transitive dependency *header*                 (compile error)
#   * a public API symbol the .so failed to export             (link error)
#   * a missing frame-plumbing symbol such as formats::MatView (link error)
#   * a missing/incomplete model bundle, e.g. one without the blendshape head
#     (runtime error from Create()).
echo "==> Verifying the package compiles, links and runs a Face Landmarker"
CHECK_SRC="$(mktemp --suffix=.cc)"
cat > "${CHECK_SRC}" <<'EOF'
#include <iostream>
#include <memory>
#include <utility>

#include <opencv2/core.hpp>

#include "mediapipe/framework/formats/image.h"
#include "mediapipe/framework/formats/image_frame.h"
#include "mediapipe/framework/formats/image_frame_opencv.h"
#include "mediapipe/tasks/cc/vision/core/running_mode.h"
#include "mediapipe/tasks/cc/vision/face_landmarker/face_landmarker.h"
#include "mediapipe/tasks/cc/vision/face_landmarker/face_landmarker_result.h"

using ::mediapipe::tasks::vision::face_landmarker::FaceLandmarker;
using ::mediapipe::tasks::vision::face_landmarker::FaceLandmarkerOptions;

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: mp_check <face_landmarker.task>\n";
        return 64;
    }
    auto options = std::make_unique<FaceLandmarkerOptions>();
    options->base_options.model_asset_path = argv[1];
    options->running_mode = ::mediapipe::tasks::vision::core::RunningMode::VIDEO;
    options->num_faces = 1;
    // Exercise the blendshape head too: a bundle without it fails here.
    options->output_face_blendshapes = true;
    auto lm = FaceLandmarker::Create(std::move(options));
    if (!lm.ok()) {
        std::cerr << "Create failed: " << lm.status().ToString() << "\n";
        return 1;
    }
    // The exact frame plumbing a downstream app uses: allocate an ImageFrame,
    // fill it through a cv::Mat view, hand it over as a mediapipe::Image.
    auto frame = std::make_shared<mediapipe::ImageFrame>(
        mediapipe::ImageFormat::SRGB, 256, 256,
        mediapipe::ImageFrame::kDefaultAlignmentBoundary);
    cv::Mat view = mediapipe::formats::MatView(frame.get());
    view.setTo(cv::Scalar(128, 128, 128));
    mediapipe::Image image(std::move(frame));
    auto r = (*lm)->DetectForVideo(image, 0);
    if (!r.ok()) {
        std::cerr << "DetectForVideo failed: " << r.status().ToString() << "\n";
        return 2;
    }
    // A flat gray image has no face in it; the point is that inference ran.
    std::cout << "faces detected in a blank frame: " << r->face_landmarks.size()
              << "\n";
    return 0;
}
EOF

# Compile the check with a given compiler. MediaPipe itself is built with Clang
# (its node framework uses C++20 constructs GCC rejects), but downstream users
# on Raspberry Pi OS reach for g++ first, so both are tried.
compile_check() {
    local cxx="$1" out="$2" log="$3"
    "${cxx}" -std=c++20 -DMEDIAPIPE_DISABLE_GPU=1 \
        -I"${INC}" $(pkg-config --cflags opencv4 2>/dev/null) "${CHECK_SRC}" \
        -L"${PREFIX}/lib" -lmediapipe_tasks \
        -Wl,-rpath-link,"${PREFIX}/lib" \
        $(pkg-config --libs opencv4 2>/dev/null) \
        -o "${out}" 2>"${log}"
}

if ! compile_check clang++ /tmp/mp_check /tmp/mp_check.log; then
    echo "!! self-check FAILED: the package could not compile+link a Face" >&2
    echo "!! Landmarker program. See the errors below (missing header => include/" >&2
    echo "!! is incomplete; undefined reference => the .so did not export the" >&2
    echo "!! symbol, check overlay/force_export.cc and overlay/libmp.BUILD)." >&2
    cat /tmp/mp_check.log >&2 || true
    rm -f "${CHECK_SRC}"
    exit 1
fi
echo "   clang++: headers compile and the API links against the .so"

RUN_RC=0
LD_LIBRARY_PATH="${PREFIX}/lib" /tmp/mp_check \
    "${PREFIX}/share/mediapipe/models/face_landmarker.task" || RUN_RC=$?
if [ "${RUN_RC}" = "132" ]; then
    # 128+SIGILL. The library is built for -mcpu=${TARGET_MCPU}; if the CI
    # runner's own CPU is older than that, it cannot execute the code even
    # though the package is fine for its actual target.
    echo "   runtime: SKIPPED - this runner's CPU does not implement" >&2
    echo "            ${TARGET_MCPU}, so the built library cannot run here." >&2
elif [ "${RUN_RC}" != "0" ]; then
    echo "!! self-check FAILED (exit ${RUN_RC}): the packaged" >&2
    echo "!! face_landmarker.task could not be loaded and run. The bundle is" >&2
    echo "!! missing, truncated, or lacks the blendshape head the check asks" >&2
    echo "!! for." >&2
    rm -f "${CHECK_SRC}"
    exit 1
else
    echo "   runtime: the packaged face_landmarker.task loads and inference runs"
fi

# GCC is only a warning: MediaPipe upstream does not support building its
# headers with GCC, so a failure here is a known-limitation signal for
# downstream users rather than a reason to withhold the package.
if compile_check g++ /tmp/mp_check_gcc /tmp/mp_check_gcc.log; then
    echo "   g++:     also compiles and links the packaged headers"
else
    echo "   g++:     WARNING - the packaged headers do NOT build with g++" >&2
    echo "            ($(g++ --version | head -n1)). Downstream projects on this" >&2
    echo "            package must use clang++. First errors:" >&2
    head -n 25 /tmp/mp_check_gcc.log >&2 || true
fi
rm -f "${CHECK_SRC}" /tmp/mp_check /tmp/mp_check_gcc

# --- Docs -----------------------------------------------------------------
cp LICENSE "${PREFIX}/share/mediapipe/LICENSE" 2>/dev/null || true
cat > "${PREFIX}/share/mediapipe/BUILD_INFO.txt" <<EOF
MediaPipe version : ${MEDIAPIPE_VERSION}
Target            : Raspberry Pi 5 (BCM2712, Cortex-A76) / 64-bit Raspberry Pi OS
Built on          : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || echo Debian) (aarch64)
glibc             : $(dpkg-query -W -f='${Version}' libc6 2>/dev/null || echo unknown)
OpenCV linked     : $(dpkg-query -W -f='${Version}' libopencv-dev 2>/dev/null || echo unknown)
                    (linked by soname -- the target OS must have the same one)
Code generation   : -mcpu=${TARGET_MCPU} -O3 (ARMv8.2-A; will SIGILL on Pi 4 and older)
Built with        : $(bazel version 2>/dev/null | head -n1 || echo bazel)
GPU               : disabled (MEDIAPIPE_DISABLE_GPU=1, CPU/TFLite inference)
EOF

echo "${VER}" > "${WORKSPACE_DIR}/dist/version.txt"

echo "==> Fixing ownership so host tooling can read the staging tree"
chown -R "$(stat -c '%u:%g' "${WORKSPACE_DIR}")" "${WORKSPACE_DIR}/dist" || true

echo "==> Done. Staged tree:"
du -sh "${PREFIX}" || true
find "${PREFIX}" -maxdepth 3 -type f | head -n 60 || true
