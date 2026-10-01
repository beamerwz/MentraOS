import {useState, useEffect} from "react"

import {
  CAPTION_TIMEOUT_OPTIONS_SECONDS,
  DEFAULT_CAPTION_TIMEOUT_SECONDS,
  type CaptionPosition,
} from "../../shared/types"
import type {CaptionSettings} from "../hooks/useSettings"
import {DisplayPreview} from "../hooks/useTranscripts"

const G2_LABS = process.env.MENTRA_PUBLIC_G2_LABS === "1"

type G2ModelChoice = {
  key: string
  name: string
  active: boolean
}

type G2ModelState = {
  type: "g2_model_state"
  currentName: string
  models: G2ModelChoice[]
}

function postG2HostMessage(message: Record<string, unknown>) {
  const hostWindow = window as Window & {ReactNativeWebView?: {postMessage: (payload: string) => void}}
  hostWindow.ReactNativeWebView?.postMessage(JSON.stringify(message))
}

interface SettingsProps {
  settings: CaptionSettings | null
  canPosition: boolean
  displayPreview: DisplayPreview | null
  accentColor?: string
  accentForeground?: string
  onUpdateUseOfflineStt: (enabled: boolean) => Promise<boolean>
  onUpdateDisplayLines: (lines: number) => Promise<boolean>
  onUpdateDisplayWidth: (width: number) => Promise<boolean>
  onUpdateCaptionPosition: (position: CaptionPosition) => Promise<boolean>
  onUpdateWordBreaking: (enabled: boolean) => Promise<boolean>
  onUpdateCaptionTimeoutSeconds: (seconds: number) => Promise<boolean>
}

export function Settings({
  settings,
  canPosition,
  displayPreview,
  accentColor = "#6DAEA6",
  accentForeground = "#FFFFFF",
  onUpdateUseOfflineStt,
  onUpdateDisplayLines,
  onUpdateDisplayWidth,
  onUpdateCaptionPosition,
  onUpdateWordBreaking,
  onUpdateCaptionTimeoutSeconds,
}: SettingsProps) {
  const [useOfflineStt, setUseOfflineStt] = useState(settings?.useOfflineStt ?? false)
  const [displayLines, setDisplayLines] = useState(settings?.displayLines || 3)
  const [displayWidth, setDisplayWidth] = useState(settings?.displayWidth || 1)
  const [captionPosition, setCaptionPosition] = useState<CaptionPosition>(settings?.captionPosition || "top")
  const [wordBreaking, setWordBreaking] = useState(settings?.wordBreaking ?? false)
  const [captionTimeoutSeconds, setCaptionTimeoutSeconds] = useState(
    settings?.captionTimeoutSeconds ?? DEFAULT_CAPTION_TIMEOUT_SECONDS,
  )
  const [g2Models, setG2Models] = useState<G2ModelChoice[]>([])
  const [g2CurrentModel, setG2CurrentModel] = useState("Loading model…")

  useEffect(() => {
    if (!G2_LABS) return

    const onModelState = (event: Event) => {
      const detail = (event as CustomEvent<G2ModelState>).detail
      if (!detail || detail.type !== "g2_model_state") return
      setG2CurrentModel(detail.currentName)
      setG2Models(Array.isArray(detail.models) ? detail.models : [])
    }

    window.addEventListener("g2-model-state", onModelState)
    postG2HostMessage({type: "g2_model_request"})
    return () => window.removeEventListener("g2-model-state", onModelState)
  }, [])

  // Sync local state with props when settings change (e.g., from SSE update or initial load)
  useEffect(() => {
    if (settings) {
      setUseOfflineStt(settings.useOfflineStt)
      setDisplayLines(settings.displayLines)
      setDisplayWidth(settings.displayWidth)
      setCaptionPosition(settings.captionPosition)
      setWordBreaking(settings.wordBreaking)
      setCaptionTimeoutSeconds(settings.captionTimeoutSeconds)
    }
  }, [settings])

  const handleUseOfflineSttChange = async (enabled: boolean) => {
    setUseOfflineStt(enabled)
    const success = await onUpdateUseOfflineStt(enabled)
    if (!success) {
      setUseOfflineStt(settings?.useOfflineStt ?? false)
    }
  }

  const handleDisplayLinesChange = async (lines: number) => {
    setDisplayLines(lines) // Optimistic update
    const success = await onUpdateDisplayLines(lines)
    if (!success) {
      // Revert on failure
      setDisplayLines(settings?.displayLines || 3)
    }
  }

  const handleDisplayWidthChange = async (width: number) => {
    setDisplayWidth(width) // Optimistic update
    const success = await onUpdateDisplayWidth(width)
    if (!success) {
      // Revert on failure
      setDisplayWidth(settings?.displayWidth || 1)
    }
  }

  const handleCaptionPositionChange = async (position: CaptionPosition) => {
    setCaptionPosition(position)
    const success = await onUpdateCaptionPosition(position)
    if (!success) {
      setCaptionPosition(settings?.captionPosition || "top")
    }
  }

  const handleWordBreakingChange = async (enabled: boolean) => {
    setWordBreaking(enabled) // Optimistic update
    const success = await onUpdateWordBreaking(enabled)
    if (!success) {
      // Revert on failure
      setWordBreaking(settings?.wordBreaking ?? false)
    }
  }

  const handleCaptionTimeoutChange = async (seconds: number) => {
    setCaptionTimeoutSeconds(seconds)
    const success = await onUpdateCaptionTimeoutSeconds(seconds)
    if (!success) {
      setCaptionTimeoutSeconds(settings?.captionTimeoutSeconds ?? DEFAULT_CAPTION_TIMEOUT_SECONDS)
    }
  }

  if (!settings) {
    return (
      <div className="flex items-center justify-center h-full">
        <p className="text-gray-500 dark:text-zinc-400">Loading settings...</p>
      </div>
    )
  }

  return (
    <div className="h-full overflow-y-auto px-4 py-6 space-y-6 bg-zinc-100 dark:bg-zinc-950">
      {/* Preview Section */}
      <div className="space-y-3">
        <h3 className="text-base font-semibold text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">Preview</h3>
        <div
          className={`p-4 bg-white dark:bg-zinc-900 rounded-2xl shadow-sm border border-gray-100 dark:border-zinc-800 h-[180px] overflow-x-auto overflow-y-hidden flex flex-col ${
            captionPosition === "bottom" && canPosition ? "justify-end" : "justify-start"
          }`}>
          {displayPreview?.text ? (
            <div className="space-y-0.5">
              {displayPreview.lines.map((line, i) => (
                <p
                  key={i}
                  className={`text-xs font-['Red_Hat_Display'] leading-tight whitespace-pre ${
                    displayPreview.isFinal ? "text-gray-800 dark:text-zinc-200" : "text-gray-500 dark:text-zinc-400"
                  }`}>
                  {line || "\u00A0"} {/* Non-breaking space for empty lines */}
                </p>
              ))}
            </div>
          ) : (
            <p className="text-gray-400 dark:text-zinc-500 text-sm font-['Red_Hat_Display'] leading-relaxed italic">
              Captions will appear here
            </p>
          )}
        </div>
      </div>

      {/* Speech-to-Text Settings */}
      <div className="space-y-4">
        <h2 className="text-base font-semibold text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
          Speech to Text
        </h2>

        <div className="bg-white dark:bg-zinc-900 rounded-2xl p-4 shadow-sm border border-gray-100 dark:border-zinc-800">
          <div className="flex items-center justify-between gap-4">
            <div className="min-w-0">
              <p className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                Use Offline Speech to Text Models
              </p>
              <p className="mt-1 text-sm text-gray-500 dark:text-zinc-400 font-['Red_Hat_Display']">
                Uses the downloaded on-device model instead of cloud transcription.
              </p>
            </div>
            <button
              onClick={() => handleUseOfflineSttChange(!useOfflineStt)}
              className={`relative inline-flex h-7 w-12 shrink-0 items-center rounded-full transition-colors ${
                useOfflineStt ? "" : "bg-gray-300 dark:bg-zinc-600"
              }`}
              style={useOfflineStt ? {backgroundColor: accentColor} : {}}
              role="switch"
              aria-label="Use Offline Speech to Text Models"
              aria-checked={useOfflineStt}>
              <span
                className={`inline-block h-5 w-5 transform rounded-full bg-white shadow-sm transition-transform ${
                  useOfflineStt ? "translate-x-6" : "translate-x-1"
                }`}
              />
            </button>
          </div>
        </div>

        {G2_LABS && (
          <div className="bg-[#100b16] rounded-2xl p-4 border border-[#2d2039]">
            <div className="flex items-start justify-between gap-3 mb-3">
              <div className="min-w-0">
                <p className="text-sm font-semibold text-white font-['Red_Hat_Display']">Speech model</p>
                <p className="mt-1 text-xs text-[#9b8cae] font-['Red_Hat_Display'] truncate">
                  Active: {g2CurrentModel}
                </p>
              </div>
              <button
                onClick={() => postG2HostMessage({type: "g2_model_request"})}
                className="shrink-0 px-3 py-2 rounded-xl border border-[#392b49] bg-[#17101f] text-[#c4b5fd] text-xs font-semibold">
                Refresh
              </button>
            </div>

            {g2Models.length === 0 ? (
              <p className="text-xs text-[#756981]">Downloaded models will appear here automatically.</p>
            ) : (
              <div className="space-y-2">
                {g2Models.map((model) => (
                  <div
                    key={model.key}
                    className="flex items-center gap-3 rounded-xl border border-[#241a2d] bg-[#0b0710] px-3 py-3">
                    <p className="min-w-0 flex-1 text-sm font-medium text-white truncate">{model.name}</p>
                    <button
                      disabled={model.active}
                      onClick={() => postG2HostMessage({type: "g2_model_switch", key: model.key})}
                      className={
                        model.active
                          ? "shrink-0 rounded-lg bg-[#17301f] px-3 py-2 text-[11px] font-bold text-[#6fe3a5]"
                          : "shrink-0 rounded-lg bg-[#6d35a8] px-3 py-2 text-[11px] font-bold text-white"
                      }>
                      {model.active ? "ACTIVE" : "SWITCH"}
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Glasses Display Settings */}
      <div className="space-y-4">
        <h2 className="text-base font-semibold text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
          Glasses Display Settings
        </h2>

        <div className="bg-white dark:bg-zinc-900 rounded-2xl p-4 shadow-sm border border-gray-100 dark:border-zinc-800 space-y-6">
          {/* Display Lines */}
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="text-gray-900 dark:text-zinc-50">
                <path d="M4 8V5a1 1 0 0 1 1-1h3" />
                <path d="M16 4h3a1 1 0 0 1 1 1v3" />
                <path d="M20 16v3a1 1 0 0 1-1 1h-3" />
                <path d="M8 20H5a1 1 0 0 1-1-1v-3" />
              </svg>
              <span className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                Display lines
              </span>
            </div>

            <div className="grid grid-cols-4 gap-2">
              {[2, 3, 4, 5].map((lines) => (
                <button
                  key={lines}
                  onClick={() => handleDisplayLinesChange(lines)}
                  className={`py-3 rounded-xl text-lg font-medium font-['Red_Hat_Display'] transition-colors ${
                    displayLines === lines
                      ? "shadow-sm"
                      : "bg-gray-50 dark:bg-zinc-800 text-gray-900 dark:text-zinc-50 hover:bg-gray-100 dark:hover:bg-zinc-700"
                  }`}
                  style={displayLines === lines ? {backgroundColor: accentColor, color: accentForeground} : {}}>
                  {lines}
                </button>
              ))}
            </div>
          </div>

          {/* Divider */}
          <div className="h-px bg-gray-100 dark:bg-zinc-800 w-full" />

          {/* Display Width */}
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="text-gray-900 dark:text-zinc-50">
                <path d="M17 8l4 4-4 4" />
                <path d="M7 16l-4-4 4-4" />
                <line x1="3" y1="12" x2="21" y2="12" />
              </svg>
              <span className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                Display Width
              </span>
            </div>

            <div className="grid grid-cols-3 gap-2">
              {[
                {value: 0, label: "Narrow"},
                {value: 1, label: "Medium"},
                {value: 2, label: "Wide"},
              ].map((option) => (
                <button
                  key={option.value}
                  onClick={() => handleDisplayWidthChange(option.value)}
                  className={`py-3 rounded-xl text-base font-medium font-['Red_Hat_Display'] transition-colors ${
                    displayWidth === option.value
                      ? "shadow-sm"
                      : "bg-gray-50 dark:bg-zinc-800 text-gray-900 dark:text-zinc-50 hover:bg-gray-100 dark:hover:bg-zinc-700"
                  }`}
                  style={displayWidth === option.value ? {backgroundColor: accentColor, color: accentForeground} : {}}>
                  {option.label}
                </button>
              ))}
            </div>
          </div>

          {/* Divider */}
          <div className="h-px bg-gray-100 dark:bg-zinc-800 w-full" />

          {/* Caption Position */}
          {canPosition && (
            <>
              <div className="space-y-3">
                <div className="flex items-center gap-3">
                  <svg
                    width="24"
                    height="24"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    className="text-gray-900 dark:text-zinc-50">
                    <path d="M8 6h8" />
                    <path d="M12 3v6" />
                    <path d="M8 18h8" />
                    <path d="M12 15v6" />
                  </svg>
                  <div>
                    <span className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                      Caption position
                    </span>
                    <p className="text-sm text-gray-500 dark:text-zinc-400 font-['Red_Hat_Display']">
                      Place captions at the top or bottom of the display
                    </p>
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-2">
                  {(["top", "bottom"] as const).map((position) => (
                    <button
                      key={position}
                      onClick={() => handleCaptionPositionChange(position)}
                      className={`py-3 rounded-xl text-base font-medium capitalize font-['Red_Hat_Display'] transition-colors ${
                        captionPosition === position
                          ? "shadow-sm"
                          : "bg-gray-50 dark:bg-zinc-800 text-gray-900 dark:text-zinc-50 hover:bg-gray-100 dark:hover:bg-zinc-700"
                      }`}
                      style={
                        captionPosition === position ? {backgroundColor: accentColor, color: accentForeground} : {}
                      }>
                      {position}
                    </button>
                  ))}
                </div>
              </div>

              <div className="h-px bg-gray-100 dark:bg-zinc-800 w-full" />
            </>
          )}

          {/* Caption Timeout */}
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="text-gray-900 dark:text-zinc-50">
                <circle cx="12" cy="12" r="9" />
                <path d="M12 7v5l3 2" />
              </svg>
              <div>
                <span className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                  Clear captions after
                </span>
                <p className="text-sm text-gray-500 dark:text-zinc-400 font-['Red_Hat_Display']">
                  Time without new speech
                </p>
              </div>
            </div>

            <div className="grid grid-cols-5 gap-2">
              {CAPTION_TIMEOUT_OPTIONS_SECONDS.map((seconds) => (
                <button
                  key={seconds}
                  onClick={() => handleCaptionTimeoutChange(seconds)}
                  className={`py-3 rounded-xl text-base font-medium font-['Red_Hat_Display'] transition-colors ${
                    captionTimeoutSeconds === seconds
                      ? "shadow-sm"
                      : "bg-gray-50 dark:bg-zinc-800 text-gray-900 dark:text-zinc-50 hover:bg-gray-100 dark:hover:bg-zinc-700"
                  }`}
                  style={
                    captionTimeoutSeconds === seconds ? {backgroundColor: accentColor, color: accentForeground} : {}
                  }>
                  {seconds}s
                </button>
              ))}
            </div>
          </div>

          {/* Divider */}
          <div className="h-px bg-gray-100 dark:bg-zinc-800 w-full" />

          {/* Word Breaking */}
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <svg
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="text-gray-900 dark:text-zinc-50">
                <path d="M4 7h16" />
                <path d="M4 12h10" />
                <path d="M4 17h13" />
                <path d="M18 14l2 2-2 2" />
              </svg>
              <span className="text-base font-medium text-gray-900 dark:text-zinc-50 font-['Red_Hat_Display']">
                Word Breaking
              </span>
            </div>

            <div className="flex items-center justify-between p-3 bg-gray-50 dark:bg-zinc-800 rounded-xl">
              <div className="flex-1 pr-4">
                <p className="text-sm text-gray-700 dark:text-zinc-200 font-['Red_Hat_Display']">
                  {wordBreaking
                    ? "Break words with hyphens to fill each line completely"
                    : "Keep words whole, break only at spaces"}
                </p>
              </div>
              <button
                onClick={() => handleWordBreakingChange(!wordBreaking)}
                className={`relative inline-flex h-7 w-12 items-center rounded-full transition-colors ${
                  wordBreaking ? "" : "bg-gray-300 dark:bg-zinc-600"
                }`}
                style={wordBreaking ? {backgroundColor: accentColor} : {}}
                role="switch"
                aria-checked={wordBreaking}>
                <span
                  className={`inline-block h-5 w-5 transform rounded-full bg-white shadow-sm transition-transform ${
                    wordBreaking ? "translate-x-6" : "translate-x-1"
                  }`}
                />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
