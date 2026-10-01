import {Asset} from "expo-asset"
import {engine} from "@mentra/engine"
import {appRegistry, offlineSpeechModelService} from "@mentra/engine-host-internal"
import mentraAuth from "@/utils/auth/authClient"
import {cloudConfigValues} from "@/services/cloudClient"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const CAPTIONS_VERSION = "1.0.18"
const CAPTIONS_BUNDLE = require("@assets/miniapps/com.mentra.captions-1.0.18.zip")

/**
 * Install the proven Captions bundle shipped inside the IPA without contacting
 * the Mentra Store/cloud registry. This is the G2 LABS built-in app path.
 */
async function ensureBundledCaptionsInstalled(): Promise<void> {
  const installed = appRegistry.getInstalledVersions(CAPTIONS_PACKAGE)
  if (installed.includes(CAPTIONS_VERSION)) {
    console.log("G2LABS_CAPTIONS bundled captions already installed")
    await engine.miniapps.refresh()
    return
  }

  console.log("G2LABS_CAPTIONS materializing bundled asset")
  const asset = Asset.fromModule(CAPTIONS_BUNDLE)
  await asset.downloadAsync()
  const uri = asset.localUri ?? asset.uri
  if (!uri) throw new Error("Bundled Captions asset has no local URI")

  const result = await appRegistry.installFromLocalZip(uri, {
    releaseIdentity: {source: "bundled_asset", releaseId: `g2-labs-captions-${CAPTIONS_VERSION}`},
  })
  if (result.is_error()) throw result.error

  await engine.miniapps.refresh()
  console.log("G2LABS_CAPTIONS installed and projected into launcher")
}

/**
 * G2 LABS runtime bootstrap. Local captions remain the zero-login default,
 * while an optional Mentra Cloud V2 session can be enabled after sign-in.
 * Bundled Captions remains available without cloud or account access.
 */
let bootPromise: Promise<void> | null = null

export function ensureG2LabsEngineStarted(): Promise<void> {
  if (bootPromise) return bootPromise

  bootPromise = (async () => {
    console.log("G2LABS_BOOTSTRAP configure/start")

    engine.configure({
      auth: {
        getSubjectToken: async () => {
          const res = await mentraAuth.getSubjectToken()
          if (res.is_error() || !res.value.token) {
            throw new Error("G2 LABS: sign in to use Mentra Cloud")
          }
          return {token: res.value.token, type: res.value.type}
        },
        onStateChange: (callback) => {
          const pending = Promise.resolve(
            mentraAuth.onAuthStateChange((event: string, session: any) => callback(event, session)),
          )
          let resolved: (() => void) | null = null
          let cancelled = false

          void pending
            .then((res: any) => {
              const handle = res?.value ?? res
              resolved = typeof handle?.unsubscribe === "function" ? handle.unsubscribe : null
              if (cancelled) resolved?.()
            })
            .catch(() => {
              resolved = null
            })

          return {
            unsubscribe: () => {
              cancelled = true
              resolved?.()
            },
          }
        },
      },
      config: {
        ...cloudConfigValues(),
        oemId: "g2-labs",
        audioFrameSizeBytes: 40,
      },
    })

    await engine.start()
    offlineSpeechModelService.startBackgroundDownloads()

    await ensureBundledCaptionsInstalled()

    console.log("G2LABS_BOOTSTRAP ready")
  })().catch((error) => {
    bootPromise = null
    throw error
  })

  return bootPromise
}
