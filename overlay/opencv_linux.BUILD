# Description:
#   OpenCV libraries for video/image processing on Linux (aarch64 / arm64).
#
# This file replaces MediaPipe's stock third_party/opencv_linux.BUILD so that
# the header globs and include paths for the aarch64 Debian multiarch layout
# are enabled. It assumes OpenCV 4.x was installed via:
#   apt-get install libopencv-dev
# on Debian Bookworm (the base of 64-bit Raspberry Pi OS).

licenses(["notice"])  # BSD license

exports_files(["LICENSE"])

cc_library(
    name = "opencv",
    hdrs = glob([
        # For OpenCV 4.x on aarch64 Debian/Ubuntu multiarch.
        "include/aarch64-linux-gnu/opencv4/opencv2/cvconfig.h",
        "include/opencv4/opencv2/**/*.h*",
    ]),
    includes = [
        "include/aarch64-linux-gnu/opencv4/",
        "include/opencv4/",
    ],
    linkopts = [
        "-l:libopencv_core.so",
        "-l:libopencv_calib3d.so",
        "-l:libopencv_features2d.so",
        "-l:libopencv_highgui.so",
        "-l:libopencv_imgcodecs.so",
        "-l:libopencv_imgproc.so",
        "-l:libopencv_video.so",
        "-l:libopencv_videoio.so",
    ],
    visibility = ["//visibility:public"],
)
