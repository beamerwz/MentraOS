import {engine} from "@mentra/engine"
import {offlineSpeechModelService} from "@mentra/engine-host-internal"

/**
 * Minimal local/OEM bootstrap for G2 LABS.
 *
 * Pairing cannot run against an unstarted engine: the original Mentra boot
 * called MantleManager.init() after auth, which configured + started the engine
 * before any scan. G2 LABS has no account gate, so reproduce that lifecycle
 * locally with a deliberately unavailable cloud token. Bluetooth pairing,
 * native device-store hydration, status projection, device event routing,
 * offline STT and the local miniapp/display runtime are still initialized by
 * engine.start().
 */
let bootPromise: Promise<void> | null = null

export function ensureG2LabsEngineStarted(): Promise<void> {
  if (bootPromise) return bootPromise

  bootPromise = (async () => {
    console.log("G2LABS_BOOTSTRAP configure/start")

    engine.configure({
      auth: {
        getSubjectToken: async () => {
          throw new Error("G2 LABS local mode has no cloud subject token")
        },
      },
      config: {
        oemId: "g2-labs",
        // G2 LC3 frames are 40 bytes in the existing engine contract.
        audioFrameSizeBytes: 40,
      },
    })

    await engine.start()

    // Keep the proven downloadable/offline language model manager alive even
    // though G2 LABS intentionally does not initialize the Mentra account UI.
    offlineSpeechModelService.startBackgroundDownloads()

    console.log("G2LABS_BOOTSTRAP ready")
  })().catch((error) => {
    bootPromise = null
    throw error
  })

  return bootPromise
}
