# Custom MediaPipe build target injected by media-pipe-builder.
#
# It bundles the MediaPipe "Tasks Vision" C++ API (CPU / TFLite backends) into a
# single shared object, libmediapipe_tasks.so, that downstream C++ applications
# on a Raspberry Pi (aarch64) can link against together with the exported
# MediaPipe headers.
#
# This package lives at the WORKSPACE root of the MediaPipe checkout, so its
# label is //libmp:libmediapipe_tasks.so.

package(default_visibility = ["//visibility:public"])

cc_binary(
    name = "libmediapipe_tasks.so",
    linkshared = True,
    linkstatic = True,
    deps = [
        "//mediapipe/tasks/cc/vision/face_detector",
        "//mediapipe/tasks/cc/vision/face_landmarker",
        "//mediapipe/tasks/cc/vision/gesture_recognizer",
        "//mediapipe/tasks/cc/vision/hand_landmarker",
        "//mediapipe/tasks/cc/vision/image_classifier",
        "//mediapipe/tasks/cc/vision/image_embedder",
        "//mediapipe/tasks/cc/vision/image_segmenter",
        "//mediapipe/tasks/cc/vision/object_detector",
        "//mediapipe/tasks/cc/vision/pose_landmarker",
    ],
)
