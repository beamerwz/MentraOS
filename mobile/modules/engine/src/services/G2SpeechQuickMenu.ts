/**
 * G2 on-glasses Speech quick menu.
 *
 * Entry point: a synthetic item injected into the G2 native swipe menu.
 * Interaction: swipe up/down to move, single tap to activate.
 *
 * The menu deliberately pauses Captions while it owns the glasses display.
 * Choosing Offline / Cloud / a downloaded model restarts Captions headlessly,
 * so the phone UI never has to be opened.
 */

import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

import {useAppStatusStore} from "../stores/apps"
import {cloudClientService} from "./CloudClientService"
import localMiniappRuntime from "./LocalMiniappRuntime"
import sttModelManager, {type InstalledModelEntry} from "./STTModelManager"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const CAPTIONS_OFFLINE_KEY = "useOfflineStt"

type MenuScreen = "root" | "models"

type ModelChoice = {
  key: string
  label: string
  active: boolean
  code?: string
  installed?: InstalledModelEntry
}

class G2SpeechQuickMenu {
  private active = false
  private screen: MenuScreen = "root"
  private cursor = 0
  private wasCaptionsRunning = false
  private mode: "local" | "cloud" = "local"
  private currentModelName = "No offline model"
  private models: ModelChoice[] = []
  private statusLine = ""

  isActive(): boolean {
    return this.active
  }

  async open(): Promise<void> {
    if (this.active) {
      await this.render()
      return
    }

    const store = useAppStatusStore.getState()
    const captions = store.apps.find((app) => app.packageName === CAPTIONS_PACKAGE)
    this.wasCaptionsRunning = captions?.running === true

    // Captions continuously owns the display while speaking. Pause it so the
    // control surface cannot be overwritten by a transcript mid-selection.
    if (this.wasCaptionsRunning) {
      await store.stop(CAPTIONS_PACKAGE)
    }

    this.active = true
    this.screen = "root"
    this.cursor = 0
    this.statusLine = ""
    await this.refreshState()
    await this.render()
  }

  handleTouch(event: {gestureName?: string; kind?: string}): boolean {
    if (!this.active) return false
    const gesture = event.gestureName ?? event.kind ?? ""

    if (gesture === "swipe_up") {
      this.move(-1)
      void this.render()
      return true
    }
    if (gesture === "swipe_down") {
      this.move(1)
      void this.render()
      return true
    }
    if (gesture === "single_tap") {
      void this.activate()
      return true
    }
    if (gesture === "foreground_exit" || gesture === "system_exit") {
      void this.close(this.wasCaptionsRunning)
      return true
    }

    // While our screen is open, consume the rest so a double tap / controller
    // gesture does not accidentally act on the paused app underneath.
    return true
  }

  private itemCount(): number {
    return this.screen === "root" ? 5 : Math.max(1, this.models.length + 1)
  }

  private move(delta: number): void {
    const count = this.itemCount()
    this.cursor = (this.cursor + delta + count) % count
    this.statusLine = ""
  }

  private async activate(): Promise<void> {
    if (!this.active) return

    if (this.screen === "models") {
      if (this.cursor >= this.models.length) {
        this.screen = "root"
        this.cursor = 2
        await this.render()
        return
      }

      const model = this.models[this.cursor]
      this.statusLine = "Loading model..."
      await this.render()
      try {
        if (model.code) {
          await sttModelManager.activateLanguage(model.code)
        } else if (model.installed) {
          await sttModelManager.activateInstalledModel(model.installed.path)
        } else {
          throw new Error("Model target is unavailable")
        }
        await this.persistMode("local")
        await this.startCaptionsAndClose()
      } catch (error) {
        this.statusLine = error instanceof Error ? error.message : String(error)
        await this.refreshState()
        await this.render()
      }
      return
    }

    switch (this.cursor) {
      case 0:
        await this.persistMode("local")
        await this.startCaptionsAndClose()
        return
      case 1:
        await this.persistMode("cloud")
        await this.startCaptionsAndClose()
        return
      case 2:
        this.screen = "models"
        this.cursor = Math.max(0, this.models.findIndex((model) => model.active))
        if (this.cursor < 0) this.cursor = 0
        await this.render()
        return
      case 3:
        this.wasCaptionsRunning = false
        await this.close(false)
        return
      default:
        await this.close(this.wasCaptionsRunning)
    }
  }

  private async persistMode(mode: "local" | "cloud"): Promise<void> {
    this.mode = mode
    await localMiniappRuntime.setMiniappStorageValue(
      CAPTIONS_PACKAGE,
      CAPTIONS_OFFLINE_KEY,
      mode === "local" ? "true" : "false",
    )
  }

  private async startCaptionsAndClose(): Promise<void> {
    this.active = false
    await Promise.resolve(BluetoothSdk.clearDisplay()).catch(() => undefined)

    const store = useAppStatusStore.getState()
    let app = store.apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    if (!app) {
      await store.refresh()
      app = useAppStatusStore.getState().apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    }
    if (!app) {
      this.active = true
      this.statusLine = "Captions app is not installed"
      await this.render()
      return
    }

    const ok = app.running ? true : await useAppStatusStore.getState().start(app, {skipNavigation: true})
    if (!ok) {
      this.active = true
      this.statusLine = "Could not start Captions"
      await this.render()
    }
  }

  private async close(resumeCaptions: boolean): Promise<void> {
    if (!this.active) return
    this.active = false
    await Promise.resolve(BluetoothSdk.clearDisplay()).catch(() => undefined)

    if (!resumeCaptions) return

    const store = useAppStatusStore.getState()
    let app = store.apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    if (!app) {
      await store.refresh()
      app = useAppStatusStore.getState().apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    }
    if (app && !app.running) {
      await useAppStatusStore.getState().start(app, {skipNavigation: true})
    }
  }

  private async refreshState(): Promise<void> {
    try {
      const raw = await localMiniappRuntime.getMiniappStorageValue(CAPTIONS_PACKAGE, CAPTIONS_OFFLINE_KEY)
      this.mode = raw === "false" ? "cloud" : "local"
    } catch {
      this.mode = "local"
    }

    const current = await sttModelManager.getCurrentModelSummary().catch(() => ({
      code: "",
      displayName: "No offline model",
      path: "",
      custom: false,
    }))
    this.currentModelName = current.displayName

    const choices: ModelChoice[] = []
    for (const config of sttModelManager.getAvailableLanguages()) {
      try {
        if (!(await sttModelManager.isModelAvailable(config.code))) continue
        const path = sttModelManager.getModelPath(config.code)
        choices.push({
          key: `preset:${config.code}`,
          label: config.code === "it" ? "Italian Built-in" : config.displayName,
          active: current.path === path || (!current.custom && current.code === config.code),
          code: config.code,
        })
      } catch {
        // A half-installed preset should not appear on the glasses.
      }
    }

    const installed = await sttModelManager.listInstalledModels().catch(() => [])
    for (const entry of installed) {
      if (!entry.runnable) continue
      if (choices.some((choice) => choice.installed?.path === entry.path)) continue
      choices.push({
        key: `library:${entry.id}`,
        label: entry.displayName,
        active: entry.current || (!!current.path && current.path === entry.path),
        installed: entry,
      })
    }

    this.models = choices
  }

  private cropLabel(value: string, max = 31): string {
    const clean = value.replace(/\s+/g, " ").trim()
    return clean.length <= max ? clean : `${clean.slice(0, max - 1)}…`
  }

  private async render(): Promise<void> {
    if (!this.active) return

    if (this.screen === "models") {
      const rows: string[] = []
      const items = [...this.models.map((model) => ({label: model.label, active: model.active})), {label: "Back", active: false}]
      const start = Math.max(0, Math.min(this.cursor - 2, Math.max(0, items.length - 5)))
      for (let index = start; index < Math.min(items.length, start + 5); index += 1) {
        const item = items[index]
        const pointer = index === this.cursor ? ">" : " "
        const active = item.active ? " *" : ""
        rows.push(`${pointer} ${this.cropLabel(item.label, 26)}${active}`)
      }

      const text = [
        "G2 SPEECH · OFFLINE MODELS",
        ...rows,
        "",
        this.statusLine || "Swipe ↑↓ · tap to select",
      ].join("\n")
      await BluetoothSdk.displayText(text)
      return
    }

    const cloud = cloudClientService.getStatus()
    const cloudLabel = cloud.status === "connected" ? "Mentra Cloud · connected" : `Mentra Cloud · ${cloud.status}`
    const rows = [
      {label: "Offline captions", active: this.mode === "local"},
      {label: cloudLabel, active: this.mode === "cloud"},
      {label: `Model: ${this.currentModelName}`, active: false},
      {label: "Stop captions", active: false},
      {label: "Exit / resume previous", active: false},
    ]

    const body = rows.map((row, index) => {
      const pointer = index === this.cursor ? ">" : " "
      const active = row.active ? " *" : ""
      return `${pointer} ${this.cropLabel(row.label, 30)}${active}`
    })

    const text = [
      "G2 SPEECH",
      "Start captions from your glasses",
      ...body,
      "",
      this.statusLine || "Swipe ↑↓ · tap",
    ].join("\n")
    await BluetoothSdk.displayText(text)
  }
}

const g2SpeechQuickMenu = new G2SpeechQuickMenu()
export default g2SpeechQuickMenu
