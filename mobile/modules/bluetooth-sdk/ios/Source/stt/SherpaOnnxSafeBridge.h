#pragma once

#if __has_include("sherpa-onnx/c-api/c-api.h")
#include "sherpa-onnx/c-api/c-api.h"
#elif __has_include("c-api/c-api.h")
#include "c-api/c-api.h"
#elif __has_include("c-api.h")
#include "c-api.h"
#else
#error "sherpa-onnx c-api.h not found"
#endif

#ifdef __cplusplus
extern "C" {
#endif

const SherpaOnnxOnlineRecognizer *MentraSherpaCreateOnlineRecognizer(
    const SherpaOnnxOnlineRecognizerConfig *config);
const SherpaOnnxOnlineStream *MentraSherpaCreateOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer);
int32_t MentraSherpaOnlineStreamSetOption(
    const SherpaOnnxOnlineStream *stream, const char *key, const char *value);
int32_t MentraSherpaOnlineStreamAcceptWaveform(
    const SherpaOnnxOnlineStream *stream, int32_t sample_rate,
    const float *samples, int32_t n);
int32_t MentraSherpaIsOnlineStreamReady(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream, int32_t *is_ready);
int32_t MentraSherpaDecodeOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream);
int32_t MentraSherpaOnlineStreamReset(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream);
const char *MentraSherpaLastError(void);

#ifdef __cplusplus
}
#endif
