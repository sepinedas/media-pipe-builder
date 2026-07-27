# media-pipe-builder

A GitHub Actions pipeline that compiles [Google MediaPipe](https://github.com/google-ai-edge/mediapipe)
from C++ source and publishes ready-to-use artifacts for **64-bit Raspberry Pi OS
(aarch64)**, targeting the **Raspberry Pi Zero 2 W**.

Each release contains:

| Artifact | What it is |
| -------- | ---------- |
| `libmediapipe_<ver>-1_arm64.deb` | A Debian installer for a Raspberry Pi Zero 2 W. Installs to `/opt/mediapipe/<ver>`, registers the shared library with `ldconfig`, and links the example binaries into `/usr/bin`. |
| `mediapipe-<ver>-aarch64-rpi.tar.gz` | The same payload as a relocatable tarball (`lib/`, `bin/`, `include/`, `share/`). |

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
  build info.

## How the build works

- Runs on GitHub's free native **`ubuntu-24.04-arm`** runners — no QEMU
  emulation, so builds complete in a reasonable time.
- The actual compilation happens inside a **`debian:bookworm`** arm64 container.
  64-bit Raspberry Pi OS is Debian Bookworm based (glibc 2.36), so binaries
  produced here run on a Pi Zero 2 W without glibc mismatches.
- MediaPipe is built with **Bazel** (via Bazelisk, honouring the pinned
  `.bazelversion`) using CPU/TFLite backends with `MEDIAPIPE_DISABLE_GPU=1`.
- The stock `third_party/opencv_linux.BUILD` is replaced (see
  [`overlay/opencv_linux.BUILD`](overlay/opencv_linux.BUILD)) to use the aarch64
  Debian multiarch OpenCV layout, and a small
  [`overlay/libmp.BUILD`](overlay/libmp.BUILD) target produces the shared library.

## Running the pipeline

**Manually** — Actions → *Build & Release MediaPipe (Raspberry Pi aarch64)* →
*Run workflow*, then choose:

- `mediapipe_version` — the MediaPipe tag to build (e.g. `v0.10.35`).
- `release_tag` — the release tag to publish (defaults to `mp-<version>`).
- `publish_release` — whether to publish a GitHub Release.

**By tag** — push a tag of the form `mp-v0.10.35` and the matching MediaPipe
version is built and released automatically.

## Using the release on a Raspberry Pi Zero 2 W

Install the `.deb` on 64-bit Raspberry Pi OS (Bookworm, aarch64):

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

Link the C++ library into your own program. MediaPipe's headers are compiled as
**C++20** and the library is built CPU-only, so define `MEDIAPIPE_DISABLE_GPU`
to match (otherwise the GPU code paths in headers like `image.h` are pulled in):

```bash
g++ -std=c++20 -DMEDIAPIPE_DISABLE_GPU=1 my_app.cc \
  -I/opt/mediapipe/<ver>/include \
  -L/opt/mediapipe/<ver>/lib -lmediapipe_tasks \
  $(pkg-config --cflags --libs opencv4) \
  -o my_app
```

> Note: MediaPipe does not ship a stable standalone C++ SDK, and its public
> headers `#include` heavy transitive dependencies (Abseil, protobuf, Eigen,
> flatbuffers, glog). Those dependency **headers are bundled** into `include/`
> at the exact versions the library was built against — do **not** substitute
> your distro's copies (this build pins protobuf 5.28 and a 2023 Abseil, far
> newer than Debian Bookworm's, so the ABIs would not match the symbols baked
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
```
