#include "SherpaOnnxSafeBridge.h"

#include <exception>
#include <string>

namespace {
thread_local std::string last_error;

template <typename F>
int32_t CatchSherpa(F &&operation) noexcept {
  try {
    last_error.clear();
    operation();
    return 1;
  } catch (const std::exception &error) {
    last_error = error.what();
  } catch (...) {
    last_error = "Unknown native sherpa-onnx exception";
  }
  return 0;
}
}  // namespace

const SherpaOnnxOnlineRecognizer *MentraSherpaCreateOnlineRecognizer(
    const SherpaOnnxOnlineRecognizerConfig *config) {
  const SherpaOnnxOnlineRecognizer *result = nullptr;
  CatchSherpa([&] { result = SherpaOnnxCreateOnlineRecognizer(config); });
  return result;
}

const SherpaOnnxOnlineStream *MentraSherpaCreateOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer) {
  const SherpaOnnxOnlineStream *result = nullptr;
  CatchSherpa([&] { result = SherpaOnnxCreateOnlineStream(recognizer); });
  return result;
}

int32_t MentraSherpaOnlineStreamSetOption(
    const SherpaOnnxOnlineStream *stream, const char *key, const char *value) {
  return CatchSherpa(
      [&] { SherpaOnnxOnlineStreamSetOption(stream, key, value); });
}

int32_t MentraSherpaOnlineStreamAcceptWaveform(
    const SherpaOnnxOnlineStream *stream, int32_t sample_rate,
    const float *samples, int32_t n) {
  return CatchSherpa([&] {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, sample_rate, samples, n);
  });
}

int32_t MentraSherpaIsOnlineStreamReady(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream, int32_t *is_ready) {
  return CatchSherpa(
      [&] { *is_ready = SherpaOnnxIsOnlineStreamReady(recognizer, stream); });
}

int32_t MentraSherpaDecodeOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream) {
  return CatchSherpa(
      [&] { SherpaOnnxDecodeOnlineStream(recognizer, stream); });
}

int32_t MentraSherpaOnlineStreamReset(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream) {
  return CatchSherpa(
      [&] { SherpaOnnxOnlineStreamReset(recognizer, stream); });
}

const char *MentraSherpaLastError(void) { return last_error.c_str(); }
