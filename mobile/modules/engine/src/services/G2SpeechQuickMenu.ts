/**
 * G2 on-glasses Captions launcher / engine submenu.
 *
 * Flow:
 *   double tap -> native G2 dashboard -> Captions
 *   Captions -> this submenu
 *   choose Mentra Cloud / Sherpa / ExecuTorch Whisper
 *   while Captions is running, another double tap stops + closes it
 */

import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

import {useAppStatusStore} from "../stores/apps"
import {useSettingsStore} from "../stores/settings"
import {cloudClientService} from "./CloudClientService"
import localMiniappRuntime from "./LocalMiniappRuntime"
import sttModelManager, {type InstalledModelEntry} from "./STTModelManager"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const CAPTIONS_OFFLINE_KEY = "useOfflineStt"

type MenuScreen = "root" | "sherpa" | "whisper"
type OfflineEngine = "sherpa" | "whisper_tiny" | "whisper_base" | "whisper_small"

type ModelChoice = {
  key: string
  label: string
  active: boolean
  code?: string
  installed?: InstalledModelEntry
}

const WHISPER_CHOICES: Array<{engine: OfflineEngine; label: string}> = [
  {engine: "whisper_tiny", label: "Whisper Tiny · fastest"},
  {engine: "whisper_base", label: "Whisper Base · balanced"},
  {engine: "whisper_small", label: "Whisper Small · accuracy"},
]

class G2SpeechQuickMenu {
  private active = false
  private screen: MenuScreen = "root"
  private cursor = 0
  private wasCaptionsRunning = false
  private mode: "local" | "cloud" = "local"
  private offlineEngine: OfflineEngine = "sherpa"
  private currentModelName = "Italian Built-in"
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
    if (gesture === "foreground_exit" || gesture === "system_exit" || gesture === "double_tap") {
      void this.close(this.wasCaptionsRunning)
      return true
    }

    return true
  }

  private itemCount(): number {
    if (this.screen === "sherpa") return Math.max(1, this.models.length + 1)
    if (this.screen === "whisper") return WHISPER_CHOICES.length + 1
    return 5
  }

  private move(delta: number): void {
    const count = this.itemCount()
    this.cursor = (this.cursor + delta + count) % count
    this.statusLine = ""
  }

  private async activate(): Promise<void> {
    if (!this.active) return

    if (this.screen === "sherpa") {
      if (this.cursor >= this.models.length) {
        this.screen = "root"
        this.cursor = 1
        await this.render()
        return
      }

      const model = this.models[this.cursor]
      this.statusLine = model.active ? "Starting Sherpa offline..." : "Preparing Sherpa model..."
      await this.render()
      try {
        // Nemotron 3.5 is multilingual. Keep Captions itself on AUTO so a
        // previously-selected English UI language cannot pin the local route.
        if (model.key.includes("nemotron_")) {
          await localMiniappRuntime.setMiniappStorageValue(CAPTIONS_PACKAGE, "language", "auto")
        }
        const activation = model.code
          ? await sttModelManager.activateLanguage(model.code)
          : model.installed
            ? await sttModelManager.activateInstalledModel(model.installed.path)
            : (() => {
                throw new Error("Model target is unavailable")
              })()

        await this.persistOfflineEngine("sherpa")
        await this.persistMode("local")
        if (activation === "staged-relaunch") {
          this.statusLine = "STAGED · reopen G2 app once"
          await this.refreshState()
          await this.render()
          return
        }
        await this.startCaptionsAndClose()
      } catch (error) {
        this.statusLine = error instanceof Error ? error.message : String(error)
        await this.refreshState()
        await this.render()
      }
      return
    }

    if (this.screen === "whisper") {
      if (this.cursor >= WHISPER_CHOICES.length) {
        this.screen = "root"
        this.cursor = 2
        await this.render()
        return
      }

      const choice = WHISPER_CHOICES[this.cursor]
      await this.persistOfflineEngine(choice.engine)
      await this.persistMode("local")
      this.statusLine = `${choice.label} selected`
      await this.startCaptionsAndClose()
      return
    }

    switch (this.cursor) {
      case 0:
        await this.persistMode("cloud")
        await this.startCaptionsAndClose()
        return
      case 1:
        this.screen = "sherpa"
        this.cursor = Math.max(0, this.models.findIndex((model) => model.active))
        if (this.cursor < 0) this.cursor = 0
        await this.render()
        return
      case 2: {
        this.screen = "whisper"
        const index = WHISPER_CHOICES.findIndex((choice) => choice.engine === this.offlineEngine)
        this.cursor = index >= 0 ? index : 0
        await this.render()
        return
      }
      case 3:
        this.wasCaptionsRunning = false
        await this.stopCaptionsAndClose()
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
    localMiniappRuntime.setMiniappTranscriptionRoute(
      CAPTIONS_PACKAGE,
      mode === "local" ? "forceLocal" : "cloud",
    )
  }

  private async persistOfflineEngine(engine: OfflineEngine): Promise<void> {
    this.offlineEngine = engine
    await useSettingsStore.getState().setSetting("g2_offline_engine", engine, false)
  }

  private async startCaptionsAndClose(): Promise<void> {
    this.active = false
    await Promise.resolve(BluetoothSdk.clearDisplay()).catch(() => undefined)

    // open() may have just stopped Captions. Refresh first: the old object can
    // still say running=true for a moment, which previously made this function
    // skip start() and leave the glasses stuck on "Start captions".
    await useAppStatusStore.getState().refresh()
    let store = useAppStatusStore.getState()
    let app = store.apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    if (!app) {
      await store.refresh()
      store = useAppStatusStore.getState()
      app = store.apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
    }
    if (!app) {
      this.active = true
      this.statusLine = "Captions app is not installed"
      await this.render()
      return
    }

    // If a stale running flag survived the submenu stop, force a clean
    // stop/refresh before starting. This also makes a route/model change take
    // effect immediately in the Captions background controller.
    if (app.running) {
      await store.stop(CAPTIONS_PACKAGE).catch(() => undefined)
      await new Promise<void>((resolve) => setTimeout(resolve, 120))
      await useAppStatusStore.getState().refresh()
      store = useAppStatusStore.getState()
      app = store.apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE) ?? app
    }

    const ok = await useAppStatusStore.getState().start(app, {skipNavigation: true})
    if (!ok) {
      this.active = true
      this.statusLine = "Could not start Captions"
      await this.render()
    }
  }

  private async stopCaptionsAndClose(): Promise<void> {
    this.active = false
    await useAppStatusStore.getState().stop(CAPTIONS_PACKAGE).catch(() => undefined)
    await Promise.resolve(BluetoothSdk.clearDisplay()).catch(() => undefined)
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

    const configuredEngine = String(useSettingsStore.getState().getSetting("g2_offline_engine") ?? "sherpa")
    this.offlineEngine =
      configuredEngine === "whisper_tiny" ||
      configuredEngine === "whisper_base" ||
      configuredEngine === "whisper_small"
        ? configuredEngine
        : "sherpa"

    const current = await sttModelManager.getCurrentModelSummary().catch(() => ({
      code: "",
      displayName: "No offline model",
      path: "",
      custom: false,
    }))
    this.currentModelName = current.displayName

    const choices: ModelChoice[] = []
    for (const config of await sttModelManager.getDownloadedLanguagesForQuickMenu()) {
      try {
        if (!(await sttModelManager.isModelAvailable(config.code))) continue
        const path = sttModelManager.getModelPath(config.code)
        choices.push({
          key: `preset:${config.code}`,
          label:
            config.code.startsWith("nemotron_")
              ? `${config.displayName} · MULTILINGUAL`
              : config.code === "it"
                ? "Italian Built-in"
                : config.displayName,
          active: current.path === path || (!current.custom && current.code === config.code),
          code: config.code,
        })
      } catch {
        // Ignore half-installed presets.
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

  private renderScrollingList(
    title: string,
    items: Array<{label: string; active: boolean}>,
  ): string {
    const rows: string[] = []
    const start = Math.max(0, Math.min(this.cursor - 2, Math.max(0, items.length - 5)))
    for (let index = start; index < Math.min(items.length, start + 5); index += 1) {
      const item = items[index]
      const pointer = index === this.cursor ? ">" : " "
      const active = item.active ? " *" : ""
      rows.push(`${pointer} ${this.cropLabel(item.label, 26)}${active}`)
    }
    return [title, ...rows, "", this.statusLine || "Swipe ↑↓ · tap"].join("\n")
  }

  private async render(): Promise<void> {
    if (!this.active) return

    if (this.screen === "sherpa") {
      const items = [
        ...this.models.map((model) => ({
          label: model.label,
          active: this.mode === "local" && this.offlineEngine === "sherpa" && model.active,
        })),
        {label: "Back", active: false},
      ]
      await BluetoothSdk.displayText(this.renderScrollingList("CAPTIONS · SHERPA", items))
      return
    }

    if (this.screen === "whisper") {
      const items = [
        ...WHISPER_CHOICES.map((choice) => ({
          label: choice.label,
          active: this.mode === "local" && this.offlineEngine === choice.engine,
        })),
        {label: "Back", active: false},
      ]
      await BluetoothSdk.displayText(this.renderScrollingList("CAPTIONS · EXECUTORCH", items))
      return
    }

    const cloud = cloudClientService.getStatus()
    const cloudLabel = cloud.status === "connected" ? "Mentra Cloud · connected" : `Mentra Cloud · ${cloud.status}`
    const sherpaLabel = this.offlineEngine === "sherpa" ? `Sherpa · ${this.currentModelName}` : "Sherpa offline"
    const whisperActive = this.offlineEngine.startsWith("whisper_")
    const whisperLabel = whisperActive
      ? WHISPER_CHOICES.find((choice) => choice.engine === this.offlineEngine)?.label ?? "ExecuTorch Whisper"
      : "ExecuTorch Whisper"

    const rows = [
      {label: cloudLabel, active: this.mode === "cloud"},
      {label: sherpaLabel, active: this.mode === "local" && this.offlineEngine === "sherpa"},
      {label: whisperLabel, active: this.mode === "local" && whisperActive},
      {label: "Stop captions", active: false},
      {label: "Exit", active: false},
    ]

    const body = rows.map((row, index) => {
      const pointer = index === this.cursor ? ">" : " "
      const active = row.active ? " *" : ""
      return `${pointer} ${this.cropLabel(row.label, 30)}${active}`
    })

    const text = [
      "CAPTIONS",
      "Choose speech engine",
      ...body,
      "",
      this.statusLine || "Swipe ↑↓ · tap",
    ].join("\n")
    await BluetoothSdk.displayText(text)
  }
}

const g2SpeechQuickMenu = new G2SpeechQuickMenu()
export default g2SpeechQuickMenu
