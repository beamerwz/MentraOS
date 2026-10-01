import {useEffect, useMemo, useRef, useState} from "react"
import {
  useSpeechToText,
  WHISPER_TINY,
  WHISPER_BASE,
  WHISPER_SMALL,
} from "react-native-executorch"

import BluetoothSdk from "@mentra/bluetooth-sdk/internal"
import {
  localMiniappRuntime,
  useAppStatusStore,
  useSettingsStore,
} from "@mentra/engine-host-internal"
import {toLanguageHint, toTranscriptionLanguage} from "@mentra/cloud-protocol/languages"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const CAPTIONS_OFFLINE_KEY = "useOfflineStt"
const CAPTIONS_LANGUAGE_KEY = "language"

type WhisperEngine = "whisper_tiny" | "whisper_base" | "whisper_small"

function isWhisperEngine(value: unknown): value is WhisperEngine {
  return value === "whisper_tiny" || value === "whisper_base" || value === "whisper_small"
}

function pcm16ToFloat32(input: ArrayBuffer | ArrayBufferView | number[]): Float32Array {
  const bytes =
    input instanceof ArrayBuffer
      ? new Uint8Array(input)
      : ArrayBuffer.isView(input)
        ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
        : Uint8Array.from(input)
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const samples = new Float32Array(Math.floor(bytes.byteLength / 2))
  for (let i = 0; i < samples.length; i += 1) {
    samples[i] = view.getInt16(i * 2, true) / 32768
  }
  return samples
}

/**
 * Turns the already-bundled ExecuTorch Whisper runtime into a first-class
 * G2 Captions backend.
 *
 * Captions itself still subscribes through the normal force-local miniapp
 * transcription route. This bridge owns raw G2 PCM only when a Whisper engine
 * is selected, then publishes ExecuTorch results back into that exact route.
 * Sherpa is disabled by LocalSttFallbackCoordinator while this bridge owns PCM,
 * so the two decoders never compete for the same local caption stream.
 */
export function G2WhisperCaptionBridge() {
  const captionsRunning = useAppStatusStore(
    (state) => state.apps.find((app) => app.packageName === CAPTIONS_PACKAGE)?.running === true,
  )
  const engine = useSettingsStore((state) => state.getSetting("g2_offline_engine"))
  const whisperEngine: WhisperEngine | null = isWhisperEngine(engine) ? engine : null

  const [offlineSelected, setOfflineSelected] = useState(true)
  const [captionLanguage, setCaptionLanguage] = useState("auto")

  const model = useMemo(() => {
    if (whisperEngine === "whisper_base") return WHISPER_BASE
    if (whisperEngine === "whisper_small") return WHISPER_SMALL
    return WHISPER_TINY
  }, [whisperEngine])

  // Do not fetch/load ExecuTorch resources at all unless the user actually
  // selected a Whisper backend.
  const whisper = useSpeechToText({
    model,
    preventLoad: whisperEngine == null,
  })

  const pcmSubscription = useRef<{remove: () => void} | null>(null)
  const running = useRef(false)
  const generation = useRef(0)
  const lastPartial = useRef("")

  // Captions keeps Cloud/Offline + language in its own miniapp storage.
  // Polling is intentional here: phone UI, glasses submenu, and background
  // miniapp can all mutate that storage independently.
  useEffect(() => {
    if (process.env.EXPO_PUBLIC_G2_LABS !== "1") return

    let alive = true
    const refresh = async () => {
      try {
        const [offlineRaw, languageRaw] = await Promise.all([
          localMiniappRuntime.getMiniappStorageValue(CAPTIONS_PACKAGE, CAPTIONS_OFFLINE_KEY),
          localMiniappRuntime.getMiniappStorageValue(CAPTIONS_PACKAGE, CAPTIONS_LANGUAGE_KEY),
        ])
        if (!alive) return
        setOfflineSelected(offlineRaw !== "false" && offlineRaw !== false)
        setCaptionLanguage(typeof languageRaw === "string" && languageRaw ? languageRaw : "auto")
      } catch {
        if (!alive) return
        setOfflineSelected(true)
        setCaptionLanguage("auto")
      }
    }

    void refresh()
    const timer = setInterval(() => void refresh(), 400)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [])

  useEffect(() => {
    if (process.env.EXPO_PUBLIC_G2_LABS !== "1") return

    const shouldRun = captionsRunning && offlineSelected && whisperEngine != null

    const stop = () => {
      generation.current += 1
      pcmSubscription.current?.remove()
      pcmSubscription.current = null
      if (running.current) {
        try {
          whisper.streamStop()
        } catch {
          // Stopping an already-ended stream is harmless.
        }
      }
      running.current = false
      lastPartial.current = ""
      void BluetoothSdk.updateBluetoothSettings({should_send_pcm: false}).catch(() => undefined)
    }

    if (!shouldRun) {
      stop()
      return stop
    }

    // Model loading is asynchronous. This effect reruns when isReady flips.
    if (!whisper.isReady) {
      return stop
    }

    const currentGeneration = ++generation.current
    let disposed = false

    void (async () => {
      try {
        // Explicitly keep Sherpa's native gate down while ExecuTorch owns PCM.
        await BluetoothSdk.updateBluetoothSettings({
          local_stt_fallback_active: false,
          should_send_pcm: true,
        })
        if (disposed || currentGeneration !== generation.current) return

        const canonicalLanguage =
          captionLanguage === "auto"
            ? "it-IT"
            : (toTranscriptionLanguage(captionLanguage) ?? "it-IT")
        const whisperLanguage = toLanguageHint(canonicalLanguage) ?? "it"

        const stream = whisper.stream({language: whisperLanguage})
        running.current = true
        lastPartial.current = ""

        pcmSubscription.current?.remove()
        pcmSubscription.current = BluetoothSdk.addListener("mic_pcm", (event) => {
          if (disposed || currentGeneration !== generation.current) return
          try {
            whisper.streamInsert(pcm16ToFloat32(event.pcm))
          } catch (error) {
            console.warn("G2 Whisper: PCM insert failed", error)
          }
        })

        for await (const update of stream) {
          if (disposed || currentGeneration !== generation.current) break

          const committed = update.committed.text.trim()
          if (committed) {
            localMiniappRuntime.forwardEvent(
              `transcription:${canonicalLanguage}`,
              {
                type: "transcription",
                text: committed,
                isFinal: true,
                transcribeLanguage: canonicalLanguage,
                provider: "executorch-whisper",
                __hostReceivedAt: Date.now(),
              },
              "local",
            )
            lastPartial.current = ""
          }

          const partial = update.nonCommitted.text.trim()
          if (partial && partial !== lastPartial.current) {
            lastPartial.current = partial
            localMiniappRuntime.forwardEvent(
              `transcription:${canonicalLanguage}`,
              {
                type: "transcription",
                text: partial,
                isFinal: false,
                transcribeLanguage: canonicalLanguage,
                provider: "executorch-whisper",
                __hostReceivedAt: Date.now(),
              },
              "local",
            )
          }
        }
      } catch (error) {
        console.error("G2 Whisper Captions runtime failed", error)
      } finally {
        if (currentGeneration === generation.current) {
          pcmSubscription.current?.remove()
          pcmSubscription.current = null
          running.current = false
        }
      }
    })()

    return () => {
      disposed = true
      stop()
    }
  }, [
    captionsRunning,
    offlineSelected,
    whisperEngine,
    captionLanguage,
    whisper.isReady,
    whisper,
  ])

  return null
}
