// C shim over demucs.cpp library: exposes a minimal C API for SwiftPM consumption.
// Layout of demucscpp_apply result: per-source interleaved stereo float32,
// result[src * 2*frames + 2*i + ch], src order: 0=drums 1=bass 2=other 3=vocals (4s model).

#include "model.hpp"

#include <cstdlib>
#include <cstring>
#include <string>

typedef void (*demucscpp_progress_fn)(float progress, const char *message,
                                      void *userdata);

extern "C" {

void *demucscpp_create(const char *model_path) {
  auto *model = new demucscpp::demucs_model();
  if (!demucscpp::load_demucs_model(std::string(model_path), model)) {
    delete model;
    return nullptr;
  }
  return model;
}

int demucscpp_num_sources(void *handle) {
  auto *m = static_cast<demucscpp::demucs_model *>(handle);
  return m->is_4sources ? 4 : 6;
}

// interleaved_stereo: frames * 2 floats (L,R,L,R...) at 44100 Hz.
// Returns malloc'd buffer of num_sources * 2 * frames floats, or NULL on error.
// Free with demucscpp_free_result.
float *demucscpp_apply(void *handle, const float *interleaved_stereo,
                       long frames, demucscpp_progress_fn cb, void *userdata) {
  auto *m = static_cast<demucscpp::demucs_model *>(handle);
  if (frames <= 0)
    return nullptr;

  Eigen::MatrixXf audio(2, frames);
  for (long i = 0; i < frames; ++i) {
    audio(0, i) = interleaved_stereo[2 * i];
    audio(1, i) = interleaved_stereo[2 * i + 1];
  }

  demucscpp::ProgressCallback pcb = [cb, userdata](float p,
                                                   const std::string &msg) {
    if (cb)
      cb(p, msg.c_str(), userdata);
  };

  Eigen::Tensor3dXf out = demucscpp::demucs_inference(*m, audio, pcb);

  const int nb = m->is_4sources ? 4 : 6;
  float *result = static_cast<float *>(
      std::malloc(sizeof(float) * nb * 2 * frames));
  if (!result)
    return nullptr;

  for (int src = 0; src < nb; ++src) {
    for (long i = 0; i < frames; ++i) {
      result[src * 2 * frames + 2 * i + 0] = out(src, 0, i);
      result[src * 2 * frames + 2 * i + 1] = out(src, 1, i);
    }
  }
  return result;
}

void demucscpp_free_result(float *result) { std::free(result); }

void demucscpp_destroy(void *handle) {
  delete static_cast<demucscpp::demucs_model *>(handle);
}

} // extern "C"
