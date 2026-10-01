import {useEffect, useMemo, useState} from "react"
import {
  ActivityIndicator,
  Alert,
  Linking,
  Pressable,
  ScrollView,
  Text as RNText,
  TextInput,
  View,
} from "react-native"
import * as Application from "expo-application"
import * as DocumentPicker from "expo-document-picker"
import * as RNFS from "@dr.pogodin/react-native-fs"
import {router} from "expo-router"

import {Screen} from "@/components/ignite"
import {sttModelManager as STT} from "@mentra/engine-host-internal"
import type {
  CurrentModelSummary,
  InstalledModelEntry,
  RemoteCatalogModel,
} from "@mentra/engine-host-internal"
import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

type NativeDiagnostics = {
  modelState?: string
  modelPath?: string
  lastError?: string
  lc3AgeMs?: number
  pcmAgeMs?: number
  ingestAgeMs?: number
  decodeAgeMs?: number
  transcriptAgeMs?: number
  bridgeAgeMs?: number
  displayAgeMs?: number
  firstPartialMs?: number
  partialIntervalMs?: number
  changedPartialsPerSec?: number
  decodeRtf?: number
  decodePasses?: number
  endpointCount?: number
  queueDropCount?: number
  lc3SequenceGapCount?: number
  lc3DecodeFailureCount?: number
  backgroundGlassesKeepaliveCount?: number
  backgroundAudioKeepaliveActive?: boolean
  backgroundAudioKeepaliveStarts?: number
  longestPartialGapMs?: number
  lastEndpointAgeMs?: number
  audioBacklogMs?: number
  sttToDisplayMs?: number
  speechActive?: boolean
  speechUtteranceCount?: number
  speechToFirstPartialMs?: number
  speechToDisplayMs?: number
  longestSpeechPartialGapMs?: number
}

type Metrics = {
  firstPartial: string
  partialInterval: string
  changedRate: string
  decodeRtf: string
  decoderPasses: string
  endpoints: string
  queueDrops: string
  lc3SequenceGaps: string
  lc3DecodeFailures: string
  backgroundKeepalives: string
  backgroundAudio: string
  backgroundAudioStarts: string
  longestPartialGap: string
  backlog: string
  sttToG2: string
  speechToFirstPartial: string
  speechToDisplay: string
  speechUtterances: string
  longestSpeechPartialGap: string
}

const EMPTY_DIAGNOSTICS: NativeDiagnostics = {}
const PURPLE = "#A855F7"
const PURPLE_SOFT = "#C4B5FD"
const CARD = "#100B16"
const BORDER = "#2D2039"

const RECOMMENDED = [
  {code: "it", title: "Italian Built-in · Kroko INT8", sub: "Accuracy / recovery baseline"},
  {code: "nemotron_it_80", title: "Nemotron 3.5 · 80 ms", sub: "Fastest streaming partials"},
  {code: "nemotron_it_160", title: "Nemotron 3.5 · 160 ms", sub: "Fast / balanced"},
  {code: "nemotron_it_320", title: "Nemotron 3.5 · 320 ms", sub: "Balanced context"},
  {code: "nemotron_it_560", title: "Nemotron 3.5 · 560 ms", sub: "More context / accuracy"},
  {code: "nemotron_it_1120", title: "Nemotron 3.5 · 1120 ms", sub: "Maximum context benchmark"},
] as const

function metric(value: number | undefined, decimals = 0): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return "—"
  return value.toFixed(decimals)
}

function health(ageMs: number | undefined): {label: string; color: string} {
  if (typeof ageMs !== "number" || ageMs < 0 || !Number.isFinite(ageMs)) {
    return {label: "NO DATA", color: "#ff6b8a"}
  }
  if (ageMs < 3_000) return {label: "LIVE", color: "#6fe3a5"}
  if (ageMs < 15_000) return {label: `STALE ${(ageMs / 1000).toFixed(1)}s`, color: "#f0c36b"}
  return {label: "NO RECENT DATA", color: "#ff6b8a"}
}

function modelStateLabel(state: string | undefined): {label: string; color: string} {
  switch (state) {
    case "ready":
      return {label: "READY · recognizer live", color: "#6fe3a5"}
    case "initializing":
      return {label: "INITIALIZING · model loading", color: PURPLE_SOFT}
    case "staged-relaunch":
      return {label: "STAGED · close/reopen once to swap safely", color: "#f0c36b"}
    case "failed":
      return {label: "FAILED · see error below", color: "#ff6b8a"}
    case "no-model":
      return {label: "NO MODEL LOADED", color: "#ff6b8a"}
    default:
      return {label: "UNKNOWN", color: "#8d809b"}
  }
}

function ActionButton({
  label,
  onPress,
  secondary = false,
  danger = false,
  disabled = false,
}: {
  label: string
  onPress: () => void
  secondary?: boolean
  danger?: boolean
  disabled?: boolean
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      style={({pressed}) => ({
        opacity: disabled ? 0.45 : pressed ? 0.75 : 1,
        backgroundColor: danger ? "#32111C" : secondary ? "#21182B" : "#6D35A8",
        borderWidth: 1,
        borderColor: danger ? "#6B2438" : secondary ? "#392B49" : "#7C3AED",
        paddingHorizontal: 12,
        paddingVertical: 9,
        borderRadius: 11,
      })}>
      <RNText style={{color: danger ? "#FF93AA" : "white", fontSize: 11, fontWeight: "800"}}>{label}</RNText>
    </Pressable>
  )
}

export default function G2ModelLab() {
  const [current, setCurrent] = useState(STT.getCurrentLanguage())
  const [busy, setBusy] = useState<string | null>(null)
  const [progress, setProgress] = useState(0)
  const [status, setStatus] = useState("Ready")
  const [diagnostics, setDiagnostics] = useState<NativeDiagnostics>(EMPTY_DIAGNOSTICS)
  const [browserQuery, setBrowserQuery] = useState("italian")
  const [browserModels, setBrowserModels] = useState<RemoteCatalogModel[]>([])
  const [browserLoading, setBrowserLoading] = useState(false)
  const [browserError, setBrowserError] = useState("")
  const [sourcesOpen, setSourcesOpen] = useState(false)
  const [installedModels, setInstalledModels] = useState<InstalledModelEntry[]>([])
  const [presetDownloaded, setPresetDownloaded] = useState<Record<string, boolean>>({})
  const [currentModel, setCurrentModel] = useState<CurrentModelSummary>({
    code: "",
    displayName: "Loading current model…",
    path: "",
    custom: false,
  })
  const sourceLinks = useMemo(() => STT.getModelSourceLinks(), [])

  const refreshDiagnostics = async () => {
    try {
      const raw = await Promise.resolve(BluetoothSdk.getG2LabDiagnostics())
      setDiagnostics(raw as NativeDiagnostics)
      return raw as NativeDiagnostics
    } catch (error) {
      setDiagnostics((previous) => ({
        ...previous,
        lastError: `Benchmark API unavailable: ${error instanceof Error ? error.message : String(error)}`,
      }))
      return null
    }
  }

  const refreshCurrentModel = async () => {
    try {
      const summary = await STT.getCurrentModelSummary()
      setCurrentModel(summary)
      if (summary.code) setCurrent(summary.code)
      return summary
    } catch (error) {
      console.warn("G2 Model Lab: current-model refresh failed", error)
      return null
    }
  }

  const refreshLibrary = async () => {
    try {
      setInstalledModels(await STT.listInstalledModels())
    } catch (error) {
      console.warn("G2 Model Lab: library refresh failed", error)
    }
  }

  const refreshPresetDownloads = async () => {
    const next: Record<string, boolean> = {}
    for (const item of RECOMMENDED) {
      try {
        next[item.code] = (await STT.getLanguageInfo(item.code)).downloaded
      } catch {
        next[item.code] = false
      }
    }
    setPresetDownloaded(next)
  }

  const refreshModelState = async () => {
    await Promise.all([refreshCurrentModel(), refreshLibrary(), refreshPresetDownloads()])
  }

  useEffect(() => {
    void STT.getCurrentLanguageFromPreferences().then((value) => value && setCurrent(value))
    void refreshModelState()
    void refreshDiagnostics()
    const timer = setInterval(() => void refreshDiagnostics(), 500)
    return () => clearInterval(timer)
  }, [])

  const metrics = useMemo<Metrics>(
    () => ({
      firstPartial: metric(diagnostics.firstPartialMs),
      partialInterval: metric(diagnostics.partialIntervalMs),
      changedRate: metric(diagnostics.changedPartialsPerSec, 1),
      decodeRtf: metric(diagnostics.decodeRtf, 2),
      decoderPasses: metric(diagnostics.decodePasses),
      endpoints: metric(diagnostics.endpointCount),
      queueDrops: metric(diagnostics.queueDropCount),
      lc3SequenceGaps: metric(diagnostics.lc3SequenceGapCount),
      lc3DecodeFailures: metric(diagnostics.lc3DecodeFailureCount),
      backgroundKeepalives: metric(diagnostics.backgroundGlassesKeepaliveCount),
      backgroundAudio: diagnostics.backgroundAudioKeepaliveActive === true ? "ACTIVE" : "OFF",
      backgroundAudioStarts: metric(diagnostics.backgroundAudioKeepaliveStarts),
      longestPartialGap: metric(diagnostics.longestPartialGapMs),
      backlog: metric(diagnostics.audioBacklogMs),
      sttToG2: metric(diagnostics.sttToDisplayMs),
      speechToFirstPartial: metric(diagnostics.speechToFirstPartialMs),
      speechToDisplay: metric(diagnostics.speechToDisplayMs),
      speechUtterances: metric(diagnostics.speechUtteranceCount),
      longestSpeechPartialGap: metric(diagnostics.longestSpeechPartialGapMs),
    }),
    [diagnostics],
  )

  const runtimeState = modelStateLabel(diagnostics.modelState)
  const appVersion = Application.nativeApplicationVersion || "3.1.5"
  const readyLibraryModels = installedModels.filter((entry) => entry.runnable)
  const downloadedFiles = installedModels.filter((entry) => !entry.runnable)

  const activate = async (code: string) => {
    try {
      setBusy(code)
      setProgress(0)
      const info = await STT.getLanguageInfo(code)
      if (!info.downloaded) {
        setStatus(`Downloading ${info.displayName}…`)
        await STT.downloadModel(code, (p) => setProgress(p.percentage))
      }
      setStatus("Validating + loading model…")
      await STT.activateLanguage(code)
      await refreshModelState()
      const snapshot = await refreshDiagnostics()
      if (snapshot?.modelState === "ready") setStatus("MODEL LIVE · open Captions and speak")
      else if (snapshot?.modelState === "staged-relaunch") setStatus("MODEL STAGED · close/reopen once")
      else setStatus("Model selected · runtime finishing initialization")
    } catch (error: any) {
      setStatus(error?.message ?? "Model activation failed")
      await refreshDiagnostics()
    } finally {
      setBusy(null)
      setProgress(0)
    }
  }

  const importCustom = async () => {
    try {
      const picked = await DocumentPicker.getDocumentAsync({type: "*/*", copyToCacheDirectory: true})
      if (picked.canceled) return
      const asset = picked.assets[0]
      setBusy("custom")
      setStatus("Installing custom Sherpa model…")
      const temp = `${RNFS.TemporaryDirectoryPath}/g2labs-custom-model.tar.bz2`
      if (await RNFS.exists(temp)) await RNFS.unlink(temp)
      const source = decodeURIComponent(asset.uri.replace("file://", ""))
      await RNFS.copyFile(source, temp)
      await STT.importCustomArchive(temp, "it-IT", asset.name || "Custom Sherpa model")
      await RNFS.unlink(temp).catch(() => undefined)
      await refreshModelState()
      setStatus(`INSTALLED + SELECTED · ${asset.name}`)
      await refreshDiagnostics()
    } catch (error: any) {
      setStatus(error?.message ?? "Custom import failed")
    } finally {
      setBusy(null)
    }
  }

  const searchModelBrowser = async () => {
    try {
      setBrowserLoading(true)
      setBrowserError("")
      setBrowserModels(await STT.browseRemoteModels(browserQuery))
    } catch (error: any) {
      setBrowserError(error?.message ?? "Could not load model sources")
    } finally {
      setBrowserLoading(false)
    }
  }

  const useInstalled = async (entry: InstalledModelEntry) => {
    try {
      setBusy(`library:${entry.id}`)
      setStatus(`Loading ${entry.displayName}…`)
      await STT.activateInstalledModel(entry.path)
      await refreshModelState()
      await refreshDiagnostics()
      setStatus(`SELECTED · ${entry.displayName}`)
    } catch (error: any) {
      setStatus(error?.message ?? "Could not activate downloaded model")
    } finally {
      setBusy(null)
    }
  }

  const deleteInstalled = (entry: InstalledModelEntry) => {
    Alert.alert(
      "Delete downloaded model?",
      entry.current
        ? `${entry.displayName} is active. G2 Glasses will switch back to Italian Built-in before deleting it.`
        : entry.displayName,
      [
        {text: "Cancel", style: "cancel"},
        {
          text: "Delete",
          style: "destructive",
          onPress: () => {
            void (async () => {
              try {
                setBusy(`delete:${entry.id}`)
                await STT.deleteInstalledModel(entry.path)
                await refreshModelState()
                await refreshDiagnostics()
                setStatus(`Deleted · ${entry.displayName}`)
              } catch (error: any) {
                setStatus(error?.message ?? "Could not delete model")
              } finally {
                setBusy(null)
              }
            })()
          },
        },
      ],
    )
  }

  const handleRemoteModel = async (model: RemoteCatalogModel) => {
    const installed = installedModels.find((entry) => entry.id === model.id)
    if (installed) {
      if (installed.runnable) await useInstalled(installed)
      else setStatus(`DOWNLOADED · ${installed.displayName} · ${installed.runtime} adapter required`)
      return
    }

    const hasDirectDownload = !!model.downloadUrl || !!model.directFiles?.length
    if (!hasDirectDownload) {
      await Linking.openURL(model.sourceUrl)
      return
    }

    try {
      setBusy(`remote:${model.id}`)
      setProgress(0)
      if (model.downloadMode === "test") {
        setStatus(`Downloading + installing ${model.displayName}…`)
        await STT.downloadAndTestCatalogModel(model, (p) => setProgress(p.percentage))
        await refreshModelState()
        await refreshDiagnostics()
        setStatus(`INSTALLED + SELECTED · ${model.displayName}`)
      } else {
        setStatus(`Downloading ${model.displayName}…`)
        await STT.downloadCatalogModelToLibrary(model, (p) => setProgress(p.percentage))
        await refreshLibrary()
        setStatus(`DOWNLOADED · ${model.displayName} · waiting for ${model.runtime} runtime adapter`)
      }
    } catch (error: any) {
      setStatus(error?.message ?? "Remote model download failed safely")
      await refreshDiagnostics()
    } finally {
      setBusy(null)
      setProgress(0)
    }
  }

  const resetBenchmark = async () => {
    try {
      await Promise.resolve(BluetoothSdk.resetG2LabDiagnostics())
      setDiagnostics(EMPTY_DIAGNOSTICS)
      setStatus("Benchmark reset · open Captions and speak")
      await refreshDiagnostics()
    } catch (error: any) {
      setStatus(error?.message ?? "Could not reset benchmark")
    }
  }

  const pipeline = [
    ["G2 LC3 packets", diagnostics.lc3AgeMs],
    ["LC3 → PCM", diagnostics.pcmAgeMs],
    ["PCM → Sherpa", diagnostics.ingestAgeMs],
    ["Sherpa decode", diagnostics.decodeAgeMs],
    ["Transcript result", diagnostics.transcriptAgeMs],
    ["Native bridge", diagnostics.bridgeAgeMs],
    ["Display command", diagnostics.displayAgeMs],
  ] as const

  return (
    <Screen
      preset="fixed"
      safeAreaEdges={["top"]}
      backgroundColor="#050208"
      className="px-0"
      statusBarStyle="light">
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{paddingHorizontal: 20, paddingTop: 10, paddingBottom: 64}}>
        <Pressable onPress={() => router.back()} style={{paddingVertical: 8}}>
          <RNText style={{color: PURPLE_SOFT, fontSize: 16}}>‹ Back</RNText>
        </Pressable>

        <RNText style={{color: "white", fontSize: 31, fontWeight: "900", marginTop: 8}}>Model Lab</RNText>
        <RNText style={{color: "#8F819B", fontSize: 14, marginTop: 5, marginBottom: 18}}>
          G2 Glasses · local speech models · v{appVersion}
        </RNText>

        <View style={{backgroundColor: "#160C20", borderColor: "#6D35A8", borderWidth: 1, borderRadius: 20, padding: 16}}>
          <RNText style={{color: "#8F7FA3", fontSize: 10, fontWeight: "900", letterSpacing: 1.2}}>ACTIVE MODEL</RNText>
          <RNText style={{color: "white", fontSize: 19, fontWeight: "900", marginTop: 6}}>{currentModel.displayName}</RNText>
          <RNText style={{color: PURPLE_SOFT, fontSize: 12, marginTop: 5}}>
            {currentModel.source || (currentModel.custom ? "Downloaded / custom" : "G2 Glasses preset")}
          </RNText>
        </View>

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 26, marginBottom: 10}}>
          RECOMMENDED
        </RNText>
        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, overflow: "hidden"}}>
          {RECOMMENDED.map((item, index) => {
            const selected = current === item.code
            const downloaded = presetDownloaded[item.code] === true
            return (
              <View
                key={item.code}
                style={{
                  padding: 15,
                  borderTopWidth: index === 0 ? 0 : 1,
                  borderTopColor: "#241A2D",
                  flexDirection: "row",
                  alignItems: "center",
                  gap: 12,
                }}>
                <View style={{width: 26, height: 26, borderRadius: 13, backgroundColor: "#21142D", alignItems: "center", justifyContent: "center"}}>
                  <RNText style={{color: PURPLE_SOFT, fontSize: 11, fontWeight: "900"}}>{index + 1}</RNText>
                </View>
                <View style={{flex: 1}}>
                  <RNText style={{color: "white", fontSize: 15, fontWeight: "800"}}>{item.title}</RNText>
                  <RNText style={{color: "#8F819B", fontSize: 12, marginTop: 3}}>{item.sub}</RNText>
                </View>
                <ActionButton
                  label={
                    busy === item.code
                      ? progress > 0
                        ? `${progress}%`
                        : "…"
                      : selected
                        ? "ACTIVE"
                        : downloaded
                          ? "USE"
                          : "GET"
                  }
                  onPress={() => void activate(item.code)}
                  secondary={selected}
                  disabled={!!busy || selected}
                />
              </View>
            )
          })}
        </View>

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 26, marginBottom: 10}}>
          MY MODEL LIBRARY
        </RNText>
        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 14}}>
          {readyLibraryModels.length === 0 ? (
            <RNText style={{color: "#7F708C", fontSize: 13}}>
              No custom/downloaded runnable models yet. Imported or compatible Sherpa models stay here until you delete them.
            </RNText>
          ) : (
            readyLibraryModels.map((entry, index) => (
              <View
                key={entry.path}
                style={{
                  paddingVertical: 12,
                  borderTopWidth: index === 0 ? 0 : 1,
                  borderTopColor: "#241A2D",
                }}>
                <View style={{flexDirection: "row", alignItems: "center", gap: 10}}>
                  <View style={{flex: 1}}>
                    <RNText style={{color: "white", fontWeight: "800", fontSize: 14}} numberOfLines={2}>
                      {entry.displayName}
                    </RNText>
                    <RNText style={{color: "#8F819B", fontSize: 11, marginTop: 4}}>
                      {entry.source} · {entry.runtime}
                    </RNText>
                  </View>
                  {entry.current && (
                    <View style={{backgroundColor: "#17301F", borderRadius: 999, paddingHorizontal: 9, paddingVertical: 5}}>
                      <RNText style={{color: "#6FE3A5", fontSize: 10, fontWeight: "900"}}>ACTIVE</RNText>
                    </View>
                  )}
                </View>
                <View style={{flexDirection: "row", gap: 8, marginTop: 10, flexWrap: "wrap"}}>
                  <ActionButton
                    label={entry.current ? "SELECTED" : busy === `library:${entry.id}` ? "LOADING…" : "USE"}
                    onPress={() => void useInstalled(entry)}
                    disabled={!!busy || entry.current}
                  />
                  {entry.sourceUrl ? (
                    <ActionButton label="SOURCE" secondary onPress={() => void Linking.openURL(entry.sourceUrl!)} />
                  ) : null}
                  <ActionButton
                    label={busy === `delete:${entry.id}` ? "DELETING…" : "DELETE"}
                    danger
                    onPress={() => deleteInstalled(entry)}
                    disabled={!!busy}
                  />
                </View>
              </View>
            ))
          )}

          <Pressable
            onPress={() => void importCustom()}
            disabled={!!busy}
            style={{
              marginTop: readyLibraryModels.length ? 10 : 14,
              borderWidth: 1,
              borderColor: "#68418B",
              backgroundColor: "#211332",
              borderRadius: 14,
              padding: 13,
            }}>
            <RNText style={{color: "white", fontWeight: "800"}}>＋ Import Sherpa .tar.bz2</RNText>
            <RNText style={{color: "#9E8DAE", fontSize: 11, marginTop: 4}}>
              Extracts, validates, selects, and keeps the model here so you can reapply or delete it later.
            </RNText>
          </Pressable>
        </View>

        {downloadedFiles.length > 0 && (
          <>
            <RNText style={{color: "#8F7FA3", fontSize: 11, fontWeight: "900", letterSpacing: 1.2, marginTop: 18, marginBottom: 8}}>
              DOWNLOADED FILES · RUNTIME NOT INSTALLED
            </RNText>
            <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 14}}>
              {downloadedFiles.map((entry, index) => (
                <View
                  key={entry.path}
                  style={{paddingVertical: 11, borderTopWidth: index === 0 ? 0 : 1, borderTopColor: "#241A2D"}}>
                  <RNText style={{color: "white", fontWeight: "800", fontSize: 13}} numberOfLines={2}>
                    {entry.displayName}
                  </RNText>
                  <RNText style={{color: "#756981", fontSize: 11, marginTop: 4}}>
                    {entry.runtime} · downloaded only · cannot be selected yet
                  </RNText>
                  <View style={{flexDirection: "row", gap: 8, marginTop: 9}}>
                    {entry.sourceUrl ? (
                      <ActionButton label="SOURCE" secondary onPress={() => void Linking.openURL(entry.sourceUrl!)} />
                    ) : null}
                    <ActionButton
                      label={busy === `delete:${entry.id}` ? "DELETING…" : "DELETE"}
                      danger
                      onPress={() => deleteInstalled(entry)}
                      disabled={!!busy}
                    />
                  </View>
                </View>
              ))}
            </View>
          </>
        )}

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 26, marginBottom: 10}}>
          SEARCH MODELS
        </RNText>
        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 14}}>
          <RNText style={{color: "#8F819B", fontSize: 12, lineHeight: 17, marginBottom: 10}}>
            Search official Sherpa releases and selected model hubs. Compatible Sherpa models install + activate immediately; other runtimes stay clearly separated as download-only files.
          </RNText>
          <TextInput
            value={browserQuery}
            onChangeText={setBrowserQuery}
            placeholder="italian, streaming, nemotron, whisper…"
            placeholderTextColor="#6A5C77"
            autoCapitalize="none"
            autoCorrect={false}
            style={{
              color: "white",
              backgroundColor: "#17121E",
              borderWidth: 1,
              borderColor: "#392B49",
              borderRadius: 13,
              paddingHorizontal: 13,
              paddingVertical: 11,
            }}
          />
          <Pressable
            onPress={() => void searchModelBrowser()}
            disabled={browserLoading || !!busy}
            style={{backgroundColor: "#6D35A8", borderRadius: 13, padding: 12, marginTop: 9, alignItems: "center"}}>
            <RNText style={{color: "white", fontWeight: "900"}}>{browserLoading ? "SEARCHING…" : "SEARCH"}</RNText>
          </Pressable>

          {!!browserError && <RNText style={{color: "#FF829B", marginTop: 10, fontSize: 12}}>{browserError}</RNText>}

          {browserModels.slice(0, 30).map((model) => {
            const installed = installedModels.find((entry) => entry.id === model.id)
            const direct = !!model.downloadUrl || !!model.directFiles?.length
            const action =
              installed?.runnable
                ? installed.current
                  ? "ACTIVE"
                  : "USE"
                : installed
                  ? "DOWNLOADED"
                  : direct
                    ? model.downloadMode === "test"
                      ? "INSTALL + USE"
                      : "DOWNLOAD"
                    : "OPEN SOURCE"
            return (
              <View key={model.id} style={{borderTopWidth: 1, borderTopColor: "#241A2D", paddingTop: 12, marginTop: 12}}>
                <RNText style={{color: "white", fontSize: 14, fontWeight: "800"}}>{model.displayName}</RNText>
                <RNText style={{color: "#8F819B", fontSize: 11, marginTop: 4}}>
                  {model.source} · {model.runtime}
                  {typeof model.size === "number" ? ` · ${STT.formatBytes(model.size)}` : ""}
                </RNText>
                <RNText style={{color: "#756981", fontSize: 11, lineHeight: 16, marginTop: 4}}>{model.detail}</RNText>
                <View style={{flexDirection: "row", gap: 8, marginTop: 9}}>
                  <ActionButton
                    label={busy === `remote:${model.id}` ? (progress > 0 ? `${progress}%` : "WORKING…") : action}
                    onPress={() => void handleRemoteModel(model)}
                    disabled={!!busy || installed?.current === true || (installed != null && installed.runnable === false)}
                    secondary={!direct || installed != null}
                  />
                  <ActionButton label="SOURCE" secondary onPress={() => void Linking.openURL(model.sourceUrl)} />
                </View>
              </View>
            )
          })}
        </View>

        <Pressable
          onPress={() => setSourcesOpen((value) => !value)}
          style={{
            marginTop: 22,
            backgroundColor: CARD,
            borderWidth: 1,
            borderColor: BORDER,
            borderRadius: 18,
            padding: 15,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "space-between",
          }}>
          <View style={{flex: 1}}>
            <RNText style={{color: "white", fontSize: 14, fontWeight: "900"}}>Curated open-source model sources</RNText>
            <RNText style={{color: "#756981", fontSize: 11, marginTop: 4}}>
              Tap to {sourcesOpen ? "hide" : "open"} {sourceLinks.length} trusted sources.
            </RNText>
          </View>
          <RNText style={{color: PURPLE_SOFT, fontSize: 20, fontWeight: "700"}}>{sourcesOpen ? "⌃" : "⌄"}</RNText>
        </Pressable>

        {sourcesOpen && (
          <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 18, overflow: "hidden", marginTop: 8}}>
            {sourceLinks.map((source, index) => (
              <Pressable
                key={source.url}
                onPress={() => void Linking.openURL(source.url)}
                style={{padding: 14, borderTopWidth: index === 0 ? 0 : 1, borderTopColor: "#241A2D"}}>
                <RNText style={{color: PURPLE_SOFT, fontWeight: "800", fontSize: 13}}>{source.name} ↗</RNText>
                <RNText style={{color: "#756981", fontSize: 11, marginTop: 3}}>{source.detail}</RNText>
              </Pressable>
            ))}
          </View>
        )}

        {busy && <ActivityIndicator style={{marginTop: 18}} color={PURPLE_SOFT} />}
        <RNText style={{color: PURPLE_SOFT, marginTop: 14, lineHeight: 19}}>{status}</RNText>

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 26, marginBottom: 10}}>
          VOICE RUNTIMES
        </RNText>
        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 14}}>
          {[
            {
              name: "Sherpa-ONNX",
              status: "INSTALLED",
              detail: "Native G2 LABS streaming runtime. Recommended and currently supported.",
              source: "https://github.com/k2-fsa/sherpa-onnx",
            },
            {
              name: "whisper.cpp",
              status: "NOT INSTALLED",
              detail: "Models can be stored in your library now. Native iOS runtime adapter is the next integration step.",
              source: "https://github.com/ggml-org/whisper.cpp",
            },
            {
              name: "Vosk",
              status: "NOT INSTALLED",
              detail: "Models are never shown as installed unless the runtime adapter is actually present.",
              source: "https://alphacephei.com/vosk/",
            },
          ].map((runtime, index) => (
            <View
              key={runtime.name}
              style={{paddingVertical: 11, borderTopWidth: index === 0 ? 0 : 1, borderTopColor: "#241A2D"}}>
              <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10}}>
                <RNText style={{color: "white", fontSize: 14, fontWeight: "900"}}>{runtime.name}</RNText>
                <RNText
                  style={{
                    color: runtime.status === "INSTALLED" ? "#6FE3A5" : "#8F819B",
                    fontSize: 10,
                    fontWeight: "900",
                  }}>
                  {runtime.status}
                </RNText>
              </View>
              <RNText style={{color: "#756981", fontSize: 11, lineHeight: 16, marginTop: 4}}>{runtime.detail}</RNText>
              <View style={{marginTop: 8, alignSelf: "flex-start"}}>
                <ActionButton label="RUNTIME SOURCE" secondary onPress={() => void Linking.openURL(runtime.source)} />
              </View>
            </View>
          ))}
          <RNText style={{color: "#6F6279", fontSize: 10, lineHeight: 15, marginTop: 8}}>
            iOS cannot safely install executable speech engines after the IPA is signed. G2 LABS can download models/data here,
            but new native runtimes must be integrated into a new IPA build.
          </RNText>
        </View>

        <View style={{backgroundColor: CARD, borderRadius: 20, padding: 17, marginTop: 22, borderWidth: 1, borderColor: BORDER}}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "900"}}>MODEL RUNTIME</RNText>
          <RNText style={{color: runtimeState.color, marginTop: 9, fontWeight: "900"}}>{runtimeState.label}</RNText>
          {!!diagnostics.lastError && <RNText style={{color: "#FF829B", marginTop: 8, fontSize: 12}}>Last error: {diagnostics.lastError}</RNText>}
        </View>

        <View style={{backgroundColor: CARD, borderRadius: 20, padding: 17, marginTop: 16, borderWidth: 1, borderColor: BORDER}}>
          <View style={{flexDirection: "row", justifyContent: "space-between", alignItems: "center"}}>
            <RNText style={{color: "white", fontSize: 19, fontWeight: "900"}}>PIPELINE HEALTH</RNText>
            <Pressable onPress={() => void resetBenchmark()}><RNText style={{color: PURPLE_SOFT, fontWeight: "800"}}>RESET</RNText></Pressable>
          </View>
          {pipeline.map(([name, age]) => {
            const state = health(age)
            return (
              <View key={name} style={{flexDirection: "row", justifyContent: "space-between", paddingVertical: 7}}>
                <RNText style={{color: "#A99DB8"}}>{name}</RNText>
                <RNText style={{color: state.color, fontWeight: "900"}}>{state.label}</RNText>
              </View>
            )
          })}
        </View>

        <View style={{backgroundColor: CARD, borderRadius: 20, padding: 17, marginTop: 16, borderWidth: 1, borderColor: BORDER}}>
          <RNText style={{color: "white", fontSize: 19, fontWeight: "900", marginBottom: 12}}>LIVE BENCHMARK</RNText>
          {[
            ["Speech → first partial", metrics.speechToFirstPartial + " ms"],
            ["Speech → G2 display", metrics.speechToDisplay + " ms"],
            ["Detected speech runs", metrics.speechUtterances],
            ["Longest gap while speaking", metrics.longestSpeechPartialGap + " ms"],
            ["Legacy first partial", metrics.firstPartial + " ms"],
            ["Partial interval", metrics.partialInterval + " ms"],
            ["Changed partials/sec", metrics.changedRate],
            ["Decode RTF", metrics.decodeRtf],
            ["Decoder passes", metrics.decoderPasses],
            ["Endpoints / resets", metrics.endpoints],
            ["PCM queue drops", metrics.queueDrops],
            ["G2 LC3 sequence gaps", metrics.lc3SequenceGaps],
            ["G2 LC3 decode failures", metrics.lc3DecodeFailures],
            ["Background G2 keepalives", metrics.backgroundKeepalives],
            ["Background audio execution", metrics.backgroundAudio],
            ["Background audio starts", metrics.backgroundAudioStarts],
            ["Longest partial gap", metrics.longestPartialGap + " ms"],
            ["Audio backlog", metrics.backlog + " ms"],
            ["STT → display", metrics.sttToG2 + " ms"],
          ].map(([key, value]) => (
            <View key={key} style={{flexDirection: "row", justifyContent: "space-between", paddingVertical: 7, gap: 12}}>
              <RNText style={{color: "#A99DB8", flex: 1}}>{key}</RNText>
              <RNText style={{color: "white", fontWeight: "800"}}>{value}</RNText>
            </View>
          ))}
        </View>
      </ScrollView>
    </Screen>
  )
}
