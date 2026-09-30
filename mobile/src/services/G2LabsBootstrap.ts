import {Asset} from "expo-asset"
import {engine} from "@mentra/engine"
import {appRegistry, offlineSpeechModelService} from "@mentra/engine-host-internal"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const CAPTIONS_VERSION = "1.0.17"
const CAPTIONS_BUNDLE = require("@assets/miniapps/com.mentra.captions-1.0.17.zip")

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
 * Account-free G2 LABS runtime bootstrap.
 * Keeps the proven G2 transport/pairing stack and local speech model manager,
 * while replacing cloud miniapp discovery with our bundled Captions app.
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
