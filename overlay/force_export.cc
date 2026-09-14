// Force-export the Tasks Vision public entry points into libmediapipe_tasks.so.
//
// The shared library is a Bazel cc_binary(linkshared=1) whose deps are the task
// libraries. The linker only pulls object files that satisfy a reference, and
// nothing *inside* the .so references the public factory methods
// (e.g. FaceLandmarker::Create) -- they are called only by downstream code. So
// their objects get dropped and the symbols never make it into the .so's dynamic
// symbol table, and a program that links the .so fails with
// "undefined reference to FaceLandmarker::Create".
//
// Taking the address of those entry points (and constructing the default op
// resolver) here creates real references, so the linker pulls the objects in and
// -- being default-visibility in a -shared link -- exports them. The sink
// symbols are marked used + default visibility so they are never garbage
// collected.

#include <memory>
#include <utility>

#include "mediapipe/framework/formats/image.h"
#include "mediapipe/framework/formats/image_frame.h"
#include "mediapipe/framework/formats/image_frame_opencv.h"
#include "mediapipe/tasks/cc/core/mediapipe_builtin_op_resolver.h"
#include "mediapipe/tasks/cc/vision/face_landmarker/face_landmarker.h"

namespace {
using ::mediapipe::tasks::vision::face_landmarker::FaceLandmarker;
}  // namespace

extern "C" {

// A reference to FaceLandmarker::Create; pulling this object pulls the whole
// face_landmarker translation unit (Create, Detect, DetectForVideo, ...).
__attribute__((used, visibility("default")))
void* olc_mediapipe_force_export_face_landmarker =
    reinterpret_cast<void*>(&FaceLandmarker::Create);

// Constructing the default op resolver forces its constructor (referenced by
// FaceLandmarkerOptions's default member) into the library too.
__attribute__((used, visibility("default")))
void olc_mediapipe_force_keep() {
  auto r = std::make_unique<::mediapipe::tasks::core::MediaPipeBuiltinOpResolver>();
  asm volatile("" : : "r"(r.get()) : "memory");
}

// The frame-plumbing every downstream program needs before it can call a Task:
// allocate an ImageFrame, get a cv::Mat view of it to copy pixels into, and
// wrap it as a mediapipe::Image. None of these are referenced by the Tasks
// entry points above, so without this they are dropped from the .so and
// consumers fail to link against ImageFrame's constructor/destructor and
// formats::MatView.
__attribute__((used, visibility("default")))
void olc_mediapipe_force_keep_image_io() {
  auto f = std::make_shared<::mediapipe::ImageFrame>(
      ::mediapipe::ImageFormat::SRGB, 2, 2,
      ::mediapipe::ImageFrame::kDefaultAlignmentBoundary);
  cv::Mat view = ::mediapipe::formats::MatView(f.get());
  ::mediapipe::Image image(std::move(f));
  asm volatile("" : : "r"(&view), "r"(&image) : "memory");
}

}  // extern "C"
