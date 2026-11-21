// Experimental API-28 adapter. No linked/bundled ONNX Runtime of its own.
#include "onnxruntime_c_api.h"
#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#define EXPORT extern "C" __attribute__((visibility("default")))
namespace {
void error(char* dst, size_t capacity, const char* message) {
  if (dst && capacity) std::snprintf(dst, capacity, "%s", message);
}
struct Engine {
  void* library = nullptr;
  const OrtApi* api = nullptr;
  OrtEnv* env = nullptr;
  OrtSession* session = nullptr;
  OrtMemoryInfo* memory = nullptr;
  std::string version;
  ~Engine() {
    if (api) {
      if (memory) api->ReleaseMemoryInfo(memory);
      if (session) api->ReleaseSession(session);
      if (env) api->ReleaseEnv(env);
    }
    if (library) dlclose(library);
  }
  void check(OrtStatus* status) {
    if (!status) return;
    std::string message = api->GetErrorMessage(status);
    api->ReleaseStatus(status);
    throw std::runtime_error(message);
  }
};
}
EXPORT void* kokoro_g2p_alloc(size_t bytes) { return std::calloc(1, bytes); }
EXPORT void kokoro_g2p_free(void* pointer) { std::free(pointer); }
EXPORT void kokoro_g2p_destroy(void* engine) { delete static_cast<Engine*>(engine); }
EXPORT const char* kokoro_g2p_version(void* engine) {
  return static_cast<Engine*>(engine)->version.c_str();
}
EXPORT void* kokoro_g2p_create(const char* model, const char* runtime,
                             int threads, char* message, size_t capacity) {
  Engine* engine = nullptr;
  OrtSessionOptions* options = nullptr;
  try {
    engine = new Engine;
    if (threads < 1 || threads > 4) throw std::runtime_error("Invalid thread count");
#ifdef __ANDROID__
    // A consumer cannot redirect the Android bridge to a second runtime.
    if (std::string(runtime) != "libonnxruntime.so")
      throw std::runtime_error("Android must reuse Sherpa's libonnxruntime.so");
#endif
    // dlopen reuses Sherpa's loaded object in this linker namespace.
    engine->library = dlopen(runtime, RTLD_NOW | RTLD_LOCAL);
    if (!engine->library) throw std::runtime_error(dlerror());
    auto getBase = reinterpret_cast<const OrtApiBase* (*)()>(
        dlsym(engine->library, "OrtGetApiBase"));
    if (!getBase) throw std::runtime_error("OrtGetApiBase is unavailable");
    const auto* base = getBase();
    engine->version = base->GetVersionString();
    engine->api = base->GetApi(ORT_API_VERSION);
    if (!engine->api) throw std::runtime_error("ORT API 28 is unavailable");
    auto* e = engine;
    e->check(e->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "kokoro-g2p", &e->env));
    e->check(e->api->CreateSessionOptions(&options));
    e->check(e->api->SetIntraOpNumThreads(options, threads));
    e->check(e->api->SetInterOpNumThreads(options, 1));
    e->check(e->api->CreateSession(e->env, model, options, &e->session));
    e->api->ReleaseSessionOptions(options); options = nullptr;
    e->check(e->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &e->memory));
    return e;
  } catch (const std::exception& ex) {
    error(message, capacity, ex.what());
    if (options && engine && engine->api) engine->api->ReleaseSessionOptions(options);
    delete engine;
    return nullptr;
  }
}
EXPORT int kokoro_g2p_argmax(void* pointer, const int64_t* source, size_t sourceLen,
                            const int64_t* decoder, size_t decoderLen,
                            char* message, size_t capacity) {
  auto* e = static_cast<Engine*>(pointer);
  if (!e) { error(message, capacity, "Closed G2P session"); return -1; }
  OrtValue *src = nullptr, *dec = nullptr, *output = nullptr;
  OrtTensorTypeAndShapeInfo* info = nullptr;
  auto cleanup = [&]() {
    if (info) e->api->ReleaseTensorTypeAndShapeInfo(info);
    if (output) e->api->ReleaseValue(output);
    if (dec) e->api->ReleaseValue(dec);
    if (src) e->api->ReleaseValue(src);
  };
  try {
    if (!source || !decoder || sourceLen < 2 || sourceLen > 64 ||
        decoderLen < 1 || decoderLen > 63) throw std::runtime_error("G2P input length limit");
    const int64_t srcShape[] = {1, static_cast<int64_t>(sourceLen)};
    const int64_t decShape[] = {1, static_cast<int64_t>(decoderLen)};
    e->check(e->api->CreateTensorWithDataAsOrtValue(e->memory, const_cast<int64_t*>(source),
        sourceLen * sizeof(int64_t), srcShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &src));
    e->check(e->api->CreateTensorWithDataAsOrtValue(e->memory, const_cast<int64_t*>(decoder),
        decoderLen * sizeof(int64_t), decShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &dec));
    const char* names[] = {"input_ids", "decoder_input_ids"};
    const OrtValue* values[] = {src, dec};
    const char* outputs[] = {"logits"};
    e->check(e->api->Run(e->session, nullptr, names, values, 2, outputs, 1, &output));
    e->check(e->api->GetTensorTypeAndShape(output, &info));
    ONNXTensorElementDataType type;
    e->check(e->api->GetTensorElementType(info, &type));
    size_t rank;
    e->check(e->api->GetDimensionsCount(info, &rank));
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank != 3)
      throw std::runtime_error("Unexpected G2P logits type/rank");
    int64_t shape[3];
    e->check(e->api->GetDimensions(info, shape, 3));
    if (shape[0] != 1 || shape[1] != static_cast<int64_t>(decoderLen) || shape[2] != 63)
      throw std::runtime_error("Unexpected G2P logits shape");
    void* data;
    e->check(e->api->GetTensorMutableData(output, &data));
    const auto* logits = static_cast<float*>(data) + (decoderLen - 1) * 63;
    int best = 0;
    for (int i = 0; i < 63; ++i) {
      if (!std::isfinite(logits[i])) throw std::runtime_error("Non-finite G2P logits");
      if (logits[i] > logits[best]) best = i;
    }
    cleanup();
    return best;
  } catch (const std::exception& ex) {
    cleanup(); error(message, capacity, ex.what()); return -1;
  }
}
