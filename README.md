# media-pipe-builder

A GitHub Actions pipeline that compiles [Google MediaPipe](https://github.com/google-ai-edge/mediapipe)
from C++ source and publishes ready-to-use artifacts for **64-bit Raspberry Pi OS
(aarch64)**, targeting the **Raspberry Pi 5**.

Each release contains:

| Artifact | What it is |
| -------- | ---------- |
| `libmediapipe_<ver>-1_arm64.deb` | A Debian installer for a Raspberry Pi 5. Installs to `/opt/mediapipe/<ver>`, points `/opt/mediapipe/current` at it, registers the shared library with `ldconfig`, links the example binaries into `/usr/bin`, and exposes `mediapipe.pc` to pkg-config. |
| `mediapipe-<ver>-aarch64-rpi5.tar.gz` | The same payload as a relocatable tarball (`lib/`, `bin/`, `include/`, `share/`). |

The payload itself:

- **`lib/libmediapipe_tasks.so`** — the MediaPipe *Tasks Vision* C++ API (object
  detector, image classifier/embedder, hand & pose landmarkers, face
  detector/landmarker, gesture recognizer, image segmenter) bundled into one
  shared object.
- **`include/`** — MediaPipe headers plus generated protobuf headers **and the
  pinned third-party dependency headers** (Abseil, protobuf, Eigen, flatbuffers,
  glog) that MediaPipe's public headers `#include`, so `include/` is
  self-contained: a single `-Iinclude` is enough to compile against the library.
- **`bin/`** — CPU example binaries (`object_detection_cpu`, `face_detection_cpu`,
  `hand_tracking_cpu`, `pose_tracking_cpu`) with their runfiles (models/data).
- **`share/mediapipe/`** — TFLite models, graph `.pbtxt` configs, license and
  build info, plus the **Tasks model bundles** (`models/face_landmarker.task`).
  Those `.task` bundles are not in the MediaPipe source tree — Google publishes
  them separately — and without them the Tasks API has nothing to run, so the
  build downloads them into the package.
- **`lib/pkgconfig/mediapipe.pc`** — so downstream builds can just ask
  `pkg-config --cflags --libs mediapipe` instead of hardcoding the versioned
  install path (the `.deb` links it into the system pkg-config path).

## How the build works

- Runs on GitHub's free native **`ubuntu-24.04-arm`** runners — no QEMU
  emulation, so builds complete in a reasonable time.
- The actual compilation happens inside a **Debian arm64 container whose
  release matches the target Pi's OS** — `debian:trixie` by default, since
  Raspberry Pi OS for the Pi 5 is Debian 13. Override it with the
  `debian_suite` workflow input.

  > **This has to match, and it is not a detail.** The shared library links
  > OpenCV *by soname*: trixie has OpenCV 4.10 (`libopencv_core.so.410`),
  > bookworm has 4.6 (`.so.406`). A library built on the wrong release cannot
  > be loaded on the target at all. Installing the other OpenCV alongside is
  > **not** a workaround — `cv::Mat` crosses the library boundary through
  > `formats::MatView`, so two OpenCV ABIs in one process is undefined
  > behaviour that bites at runtime rather than at load. The generated
  > `Depends` names the exact OpenCV packages, so `apt` refuses the package on
  > the wrong release instead of letting you find out the hard way.
- Code generation targets the Pi 5's **Cortex-A76** (`-mcpu=cortex-a76 -O3`),
  raising the assumed baseline from generic ARMv8-A to ARMv8.2-A — dot product,
  FP16, LSE atomics — which is what the quantised TFLite kernels under the
  Tasks API want. **These artifacts are Pi 5 only**: on a Pi 4, Pi 3 or
  Zero 2 W (Cortex-A72/A53) they fault with `SIGILL`. Override with the
  `TARGET_MCPU` environment variable (e.g. `TARGET_MCPU=cortex-a72`) to build
  for a different core, or set it to `generic` for a portable build.
- MediaPipe is built with **Bazel** (via Bazelisk, honouring the pinned
  `.bazelversion`) using CPU/TFLite backends with `MEDIAPIPE_DISABLE_GPU=1`.
- The stock `third_party/opencv_linux.BUILD` is replaced (see
  [`overlay/opencv_linux.BUILD`](overlay/opencv_linux.BUILD)) to use the aarch64
  Debian multiarch OpenCV layout, and a small
  [`overlay/libmp.BUILD`](overlay/libmp.BUILD) target produces the shared library.
- Before publishing, the build **compiles, links and runs** a real Face
  Landmarker program against nothing but the packaged `include/`, `lib/` and the
  packaged `face_landmarker.task`. That gates four classes of packaging bug at
  once: a missing dependency header, a Tasks entry point the `.so` did not
  export, missing frame plumbing (`ImageFrame` / `formats::MatView`, which the
  Tasks libraries do not pull in on their own — see
  [`overlay/libmp.BUILD`](overlay/libmp.BUILD) and
  [`overlay/force_export.cc`](overlay/force_export.cc)), and a model bundle that
  is missing or lacks the blendshape head. The same program is then compiled
  with `g++` as a non-fatal check, since Raspberry Pi OS users reach for GCC
  first while MediaPipe upstream only supports Clang.

## Running the pipeline

**Manually** — Actions → *Build & Release MediaPipe (Raspberry Pi aarch64)* →
*Run workflow*, then choose:

- `mediapipe_version` — the MediaPipe tag to build (e.g. `v0.10.35`).
- `release_tag` — the release tag to publish (defaults to `mp-<version>`).
- `publish_release` — whether to publish a GitHub Release.

**By tag** — push a tag of the form `mp-v0.10.35` and the matching MediaPipe
version is built and released automatically.

## Using the release on a Raspberry Pi 5

Install the `.deb` on 64-bit Raspberry Pi OS (aarch64), on the same Debian
release the package was built for:

```bash
sudo apt-get update
sudo apt-get install -y libopencv-dev ffmpeg
sudo dpkg -i libmediapipe_*_arm64.deb
```

Run an example (needs a camera / display, or point it at a video file):

```bash
object_detection_cpu \
  --calculator_graph_config_file=/opt/mediapipe/<ver>/share/mediapipe/graphs/object_detection_desktop_live.pbtxt
```

Link the C++ library into your own program. The `.pc` file carries the include
path, the library and `-DMEDIAPIPE_DISABLE_GPU=1` (the library is CPU-only, so
that define has to match or the GPU code paths in headers like `image.h` get
pulled in). The one thing it deliberately does **not** carry is `-std=c++20`,
because a `-std` coming out of pkg-config would be overridden by whatever your
build system appends — MediaPipe's headers need C++20, so set it yourself:

```bash
g++ -std=c++20 my_app.cc $(pkg-config --cflags --libs mediapipe) -o my_app
```

With CMake:

```cmake
set(CMAKE_CXX_STANDARD 20)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MEDIAPIPE REQUIRED mediapipe)
target_include_directories(my_app PRIVATE ${MEDIAPIPE_INCLUDE_DIRS})
target_link_directories(my_app PRIVATE ${MEDIAPIPE_LIBRARY_DIRS})
target_link_libraries(my_app PRIVATE ${MEDIAPIPE_LIBRARIES})
target_compile_definitions(my_app PRIVATE MEDIAPIPE_DISABLE_GPU=1)
```

Or spell it all out by hand:

```bash
g++ -std=c++20 -DMEDIAPIPE_DISABLE_GPU=1 my_app.cc \
  -I/opt/mediapipe/<ver>/include \
  -L/opt/mediapipe/<ver>/lib -lmediapipe_tasks \
  $(pkg-config --cflags --libs opencv4) \
  -o my_app
```

MediaPipe's headers are developed and tested against **Clang**; the build warns
(but still publishes) if they do not also compile with the container's `g++`, so
if GCC rejects them, build your application with `clang++`.

The Tasks APIs load a `.task` bundle at runtime. The packaged Face Landmarker
bundle lives at:

```
/opt/mediapipe/current/share/mediapipe/models/face_landmarker.task
```

`/opt/mediapipe/current` is a symlink the `.deb` points at the version it just
installed, so applications do not have to know the version number.

> If you relocate the **tarball** rather than installing the `.deb`, edit the
> `prefix=` line at the top of `lib/pkgconfig/mediapipe.pc` (it is baked to
> `/opt/mediapipe/<ver>`) and add that directory to `PKG_CONFIG_PATH`.

> Note: MediaPipe does not ship a stable standalone C++ SDK, and its public
> headers `#include` heavy transitive dependencies (Abseil, protobuf, Eigen,
> flatbuffers, glog). Those dependency **headers are bundled** into `include/`
> at the exact versions the library was built against — do **not** substitute
> your distro's copies (this build pins protobuf 5.28 and a 2023 Abseil, far
> newer than Debian's own, so the ABIs would not match the symbols baked
> into `libmediapipe_tasks.so`). Those dependencies' implementations are
> statically linked into the shared library, so you only link `-lmediapipe_tasks`
> (plus OpenCV). For non-trivial applications, building against MediaPipe with
> Bazel remains the officially supported path — these artifacts are aimed at
> deploying the prebuilt library and CPU tools onto the device.

## Repository layout

```
.github/workflows/release.yml   # the pipeline
scripts/build_mediapipe.sh      # clones + builds MediaPipe inside the container
scripts/package_deb.sh          # builds the .deb and the tarball
overlay/opencv_linux.BUILD      # aarch64 OpenCV Bazel config
overlay/libmp.BUILD             # shared-library Bazel target
overlay/force_export.cc         # keeps the public API symbols in the .so
```

## Who uses this

[open-camera](https://github.com/sepinedas/open-camera) — a Raspberry Pi 5
camera app whose facial filters run the Face Landmarker from this package.
