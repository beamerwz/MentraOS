#pragma once

#include "sherpa-onnx/c-api/c-api.h"

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
