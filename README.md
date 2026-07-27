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
- **`include/`** — MediaPipe headers plus generated protobuf headers, so you can
  compile against the library.
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

Link the C++ library into your own program:

```bash
g++ my_app.cc \
  -I/opt/mediapipe/<ver>/include \
  -L/opt/mediapipe/<ver>/lib -lmediapipe_tasks \
  -o my_app
```

> Note: MediaPipe does not ship a stable standalone C++ SDK. The exported
> headers cover MediaPipe itself; heavy transitive dependencies (Abseil,
> protobuf, TensorFlow Lite) are statically linked into `libmediapipe_tasks.so`.
> For non-trivial applications, building against MediaPipe with Bazel remains the
> officially supported path — these artifacts are aimed at deploying the
> prebuilt library and CPU tools onto the device.

## Repository layout

```
.github/workflows/release.yml   # the pipeline
scripts/build_mediapipe.sh      # clones + builds MediaPipe inside the container
scripts/package_deb.sh          # builds the .deb and the tarball
overlay/opencv_linux.BUILD      # aarch64 OpenCV Bazel config
overlay/libmp.BUILD             # shared-library Bazel target
```
