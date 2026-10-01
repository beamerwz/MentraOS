/**
 * Device-event router — engine-owned. Subscribes to the inbound native BLE/device
 * events and routes them into the engine runtime: device stores, the process event
 * bus, the photo/stream coordinators, and local miniapps (via forwardEvent).
 *
 * Why this exists: engine owns the stores, coordinators, miniapp runtime, and facades,
 * but it never *subscribed to the device* for most events — the host MantleManager was
 * still the event router the whole runtime secretly depended on. So a bare OEM that
 * imported engine + called engine.start() got a connected runtime with almost no device
 * data flowing in (no miniapp input, dead gallery sync, starved coordinators). This
 * service moves those inbound bridges into engine so ANY host gets them.
 *
 * Scope: the engine legs only. The Cloud V1 relays that used to live beside them in
 * MantleManager (touch→cloud, the cloud-SDK stream/photo legs, etc.) were deleted with
 * Cloud V1 app end-of-life.
 *
 * Started by `engine.start()`. Idempotent.
 */
import BluetoothSdk from "@mentra/bluetooth-sdk/internal"
import {shallow} from "zustand/shallow"

import localMiniappRuntime from "./LocalMiniappRuntime"
import localSttFallbackCoordinator from "./LocalSttFallbackCoordinator"
import {phonePhotoCoordinator} from "./PhonePhotoCoordinator"
import {phoneStreamCoordinator} from "./PhoneStreamCoordinator"
import {isGlassesConnected} from "./GlassesReadiness"
import {useGlassesStore} from "../stores/glasses"
import {useSettingsStore} from "../stores/settings"
import {useAppStatusStore} from "../stores/apps"
import {retirePendingSelectionOnPromotion} from "./PairingIdentity"
import GlobalEventEmitter from "../utils/GlobalEventEmitter"
import {asgCameraApi} from "./asg/asgCameraApi"
import g2SpeechQuickMenu from "./G2SpeechQuickMenu"
import {G2_SPEECH_MENU_PACKAGE} from "./G2SpeechQuickMenuConstants"

let subs: Array<{remove: () => void}> = []

const G2_CAPTIONS_PACKAGE = "com.mentra.captions"
let lastNativeCaptionsActive: boolean | null = null

async function syncG2CaptionsNativeState(active: boolean): Promise<void> {
  if (process.env.EXPO_PUBLIC_G2_LABS !== "1") return
  if (lastNativeCaptionsActive === active) return
  lastNativeCaptionsActive = active
  try {
    await BluetoothSdk.updateBluetoothSettings({g2_captions_active: active})
  } catch (error) {
    console.warn("G2 Captions: native active-state sync failed", error)
  }
}

async function toggleG2CaptionsFromGlasses(): Promise<void> {
  const store = useAppStatusStore.getState()
  let app = store.apps.find((candidate) => candidate.packageName === G2_CAPTIONS_PACKAGE)

  if (!app) {
    await store.refresh()
    app = useAppStatusStore.getState().apps.find((candidate) => candidate.packageName === G2_CAPTIONS_PACKAGE)
  }
  if (!app) {
    console.warn("G2 Captions: bundled Captions miniapp is not installed")
    return
  }

  if (app.running) {
    await useAppStatusStore.getState().stop(G2_CAPTIONS_PACKAGE)
    await Promise.resolve(BluetoothSdk.clearDisplay()).catch(() => undefined)
    await syncG2CaptionsNativeState(false)
    return
  }

  const started = await useAppStatusStore.getState().start(app, {skipNavigation: true})
  await syncG2CaptionsNativeState(started)
}

export function startDeviceEventRouter(): void {
  if (subs.length) return

  // Keep native G2 aware of whether Captions owns the display. The native
  // double-tap handler uses this bit to suppress the dashboard on the second
  // double-tap, letting JS stop/close Captions without a menu flash.
  let previousCaptionsRunning =
    useAppStatusStore.getState().apps.find((app) => app.packageName === G2_CAPTIONS_PACKAGE)?.running === true
  void syncG2CaptionsNativeState(previousCaptionsRunning)
  subs.push({
    remove: useAppStatusStore.subscribe((state) => {
      const running = state.apps.find((app) => app.packageName === G2_CAPTIONS_PACKAGE)?.running === true
      if (running === previousCaptionsRunning) return
      previousCaptionsRunning = running
      void syncG2CaptionsNativeState(running)
    }),
  })

  // --- device state → engine stores ---

  // Standalone WiFi status → glasses store.
  subs.push(
    BluetoothSdk.addListener("wifi_status_change", (event) => {
      const {type: _type, ...wifi} = event
      useGlassesStore.getState().setGlassesInfo({wifi})
    }),
  )

  // Forward glasses Wi-Fi to miniapps (session.glasses.onWifi) from the STORE — the
  // single source of truth — so every path converges here: wifi_status_change,
  // onGlassesStatus, and BLE disconnect. Effective connectivity requires the glasses
  // to be connected AND on Wi-Fi, so a disconnect correctly flips `connected` false.
  subs.push({
    remove: useGlassesStore.subscribe(
      (s) => {
        const connected = isGlassesConnected(s.connection) && s.wifi.state === "connected"
        return {
          connected,
          ssid: s.wifi.state === "connected" ? s.wifi.ssid : undefined,
          localIp: s.wifi.state === "connected" ? s.wifi.localIp : undefined,
        }
      },
      (wifi) => localMiniappRuntime.forwardEvent("glasses_wifi", wifi),
      {equalityFn: shallow},
    ),
  })

  // Incremental battery status → glasses store + local miniapps.
  subs.push(
    BluetoothSdk.addListener("battery_status", (event) => {
      const state = useGlassesStore.getState()
      state.setBatteryInfo(event.level, event.charging, state.caseBatteryLevel, state.caseCharging)
      localMiniappRuntime.forwardEvent("glasses_battery_update", {
        type: "glasses_battery_update",
        level: event.level,
        charging: event.charging,
        timestamp: event.timestamp ?? Date.now(),
      })
    }),
  )

  // Hotspot status → glasses store + event bus. engine's own gallerySyncService listens
  // on the bus for these, so without this bridge engine's gallery sync is dead.
  subs.push(
    BluetoothSdk.addListener("hotspot_status_change", (event) => {
      const enabled = event.state === "enabled"
      const ssid = enabled ? event.ssid : ""
      const password = enabled ? event.password : ""
      const localIp = enabled ? event.localIp : ""
      useGlassesStore.getState().setHotspotInfo(enabled, ssid, password, localIp)
      // Always retarget the ASG camera client: on disable (or an event with no
      // IP) fall back to the localhost default so later calls fail fast instead
      // of hitting the previous network's stale glasses IP.
      asgCameraApi.setServer(localIp || "localhost", 8089)
      GlobalEventEmitter.emit("hotspot_status_change", {enabled, ssid, password, local_ip: localIp})
    }),
  )
  subs.push(
    BluetoothSdk.addListener("hotspot_error", (event) => {
      GlobalEventEmitter.emit("hotspot_error", {error_message: event.errorMessage, timestamp: event.timestamp})
    }),
  )

  // Glasses gallery content counts → event bus (consumed by gallerySyncService).
  subs.push(
    BluetoothSdk.addListener("gallery_status", (event) => {
      GlobalEventEmitter.emit("gallery_status", {
        photos: event.photos,
        videos: event.videos,
        total: event.total,
        has_content: event.hasContent,
        camera_busy: event.cameraBusy,
      })
    }),
  )

  // Hardware-originated setting changes (user changes a setting ON the glasses) → store.
  // The inbound complement to GlassesSettingsSync (which only pushes store→device).
  subs.push(
    BluetoothSdk.addListener("save_setting", async (event) => {
      const settings = useSettingsStore.getState()
      // Damp the relay: native re-echoes some settings unconditionally (e.g.
      // the identity block at every handleDeviceReady) — a same-value echo
      // must not become a store write (persistence churn + change-push noise).
      if (settings.getSetting(event.key) !== event.value) {
        await settings.setSetting(event.key, event.value)
      }
      // Two-phase identity: a promoted default retires the pending selection
      // marker. The rule lives with PairingIdentity (a no-op for other keys).
      await retirePendingSelectionOnPromotion(event.key, event.value)
    }),
  )

  // --- coordinators (owns()-gated) ---

  // Phone-owned photo errors settle the in-flight long-poll fast (vs. timeout).
  // Non-owned photo responses used to forward to the Cloud V1 photo pipeline via
  // restComms; that relay was removed with Cloud V1 app end-of-life, so they drop.
  // Wire v2 sends a short 4-hex BLE requestId; the coordinator maps it back to
  // the cloud requestId (resolveCloudRequestId) before ownership checks.
  subs.push(
    BluetoothSdk.addListener("photo_response", (event) => {
      const cloudRequestId = event.requestId ? phonePhotoCoordinator.resolveCloudRequestId(event.requestId) : ""
      if (cloudRequestId && phonePhotoCoordinator.owns(cloudRequestId)) {
        if (event.state === "error") {
          phonePhotoCoordinator.handlePhotoError(
            event.requestId ?? cloudRequestId,
            event.errorCode ?? "GLASSES_ERROR",
            event.errorMessage ?? "Glasses reported an error",
          )
        }
      }
    }),
  )

  // Phone-owned stream status / keep-alive → the stream coordinator. The Cloud V1 relay
  // for non-owned streams was removed with Cloud V1 app end-of-life.
  subs.push(
    BluetoothSdk.addListener("stream_status", (event) => {
      if (event.streamId && phoneStreamCoordinator.owns(event.streamId)) {
        phoneStreamCoordinator.handleGlassesStatus(event)
      }
    }),
  )
  subs.push(
    BluetoothSdk.addListener("keep_alive_ack", (event) => {
      if (event.streamId && phoneStreamCoordinator.owns(event.streamId)) {
        phoneStreamCoordinator.handleKeepAliveAck(event)
      }
    }),
  )

  // --- device input → local miniapps (forwardEvent is subscriber-gated; a no-op when
  // no miniapp listens). The v1 SocketComms cloud legs for these were removed with
  // the Cloud V1 ripout. ---

  subs.push(
    BluetoothSdk.addListener("button_press", (event) => {
      localMiniappRuntime.forwardEvent("button_press", event)
    }),
  )
  subs.push(
    BluetoothSdk.addListener("touch_event", (event) => {
      // While the on-glasses Captions engine submenu is open, its swipe/tap
      // gestures are consumed here and never leak into a paused miniapp.
      if (g2SpeechQuickMenu.handleTouch(event)) return

      if (process.env.EXPO_PUBLIC_G2_LABS === "1" && event.gestureName === "double_tap") {
        const captionsRunning =
          useAppStatusStore.getState().apps.find((app) => app.packageName === G2_CAPTIONS_PACKAGE)?.running === true

        // Native G2 owns the first double tap as dashboard open. While Captions
        // is active native suppresses that dashboard and this same event becomes
        // STOP + CLOSE.
        if (captionsRunning) void toggleG2CaptionsFromGlasses()
        return
      }

      localMiniappRuntime.forwardEvent("touch_event", event)
    }),
  )
  // G2 IMU accelerometer — payload already matches the miniapp AccelData shape.
  subs.push(
    BluetoothSdk.addListener("accel_event", (event) => {
      localMiniappRuntime.forwardEvent("accel_event", {
        x: event.x,
        y: event.y,
        z: event.z,
        timestamp: typeof event.timestamp === "number" ? event.timestamp : Date.now(),
      })
    }),
  )
  // Head position — translate native {up:boolean} → SDK {position:"up"|"down"}.
  subs.push(
    BluetoothSdk.addListener("head_up", (event) => {
      localMiniappRuntime.forwardEvent("head_up", {position: event.up ? "up" : "down", timestamp: Date.now()})
    }),
  )
  // On-device STT transcripts → local miniapps only while the local engine is
  // active (cloud fallback or an explicit forceLocal subscription). The runtime
  // filters mixed local/cloud delivery per miniapp to avoid double-delivery.
  // forwardEvent is subscriber-gated — a no-op when no miniapp listens.
  // (Was MantleManager.handle_local_transcription; its offline-captions display branch
  // went away with the pseudo captions renderer.)
  subs.push(
    BluetoothSdk.addListener("local_transcription", (event) => {
      if (!localSttFallbackCoordinator.isActive()) return
      const lang = event.transcribeLanguage ?? localSttFallbackCoordinator.getActiveLanguage() ?? "en-US"
      localMiniappRuntime.forwardEvent(`transcription:${lang}`, event, "local")
    }),
  )

  // --- glasses swipe-menu app launcher (G2) ---
  subs.push(
    BluetoothSdk.addListener("miniapp_selected", (event) => {
      const packageName = event.packageName as string
      if (!packageName) return

      if (packageName === G2_SPEECH_MENU_PACKAGE) {
        // The native dashboard item is named "Captions". Selecting it opens a
        // second-level on-glasses engine chooser: Mentra Cloud, Sherpa, or
        // ExecuTorch Whisper Tiny/Base/Small.
        void g2SpeechQuickMenu.open()
        return
      }

      const app = useAppStatusStore.getState().apps.find((a) => a.packageName === packageName)
      if (!app) return
      // Toggle: stop if running, else start.
      if (app.running) {
        useAppStatusStore.getState().stop(packageName)
      } else {
        useAppStatusStore.getState().start(app, {skipNavigation: true})
      }
    }),
  )
}

export function stopDeviceEventRouter(): void {
  for (const sub of subs) sub.remove()
  subs = []
}
