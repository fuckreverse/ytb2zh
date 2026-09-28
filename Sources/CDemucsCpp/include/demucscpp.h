#ifndef DEMUCSCPP_H
#define DEMUCSCPP_H

// demucs.cpp C API shim（静态库 vendored 于 Frameworks/demucs/lib/libdemucscpp.a）
// 上游：https://github.com/sevagh/demucs.cpp（MIT），Eigen pinned dd8c71e，BLAS → Accelerate
// 输入布局：interleaved stereo float32 @44100Hz；输出 per-source interleaved stereo
// 4 源模型顺序：0=drums 1=bass 2=other 3=vocals

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*demucscpp_progress_fn)(float progress, const char *message,
                                      void *userdata);

/// 加载 ggml 权重（htdemucs 4s/6s、hdemucs_mmi）。失败返回 NULL。
void *demucscpp_create(const char *model_path);

/// 源数量（4 或 6）
int demucscpp_num_sources(void *handle);

/// 推理：interleaved_stereo 需为 frames*2 个 float（L,R,L,R...@44100Hz）。
/// 返回 malloc 的 num_sources*2*frames float 数组（失败 NULL），用 demucscpp_free_result 释放。
float *demucscpp_apply(void *handle, const float *interleaved_stereo,
                       long frames, demucscpp_progress_fn cb, void *userdata);

void demucscpp_free_result(float *result);

void demucscpp_destroy(void *handle);

#ifdef __cplusplus
}
#endif

#endif
