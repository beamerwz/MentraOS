import {useEffect, useMemo, useState} from "react"
import {ActivityIndicator, Linking, Pressable, ScrollView, Text as RNText, TextInput, View} from "react-native"
import * as Application from "expo-application"
import * as DocumentPicker from "expo-document-picker"
import * as RNFS from "@dr.pogodin/react-native-fs"
import {router} from "expo-router"

import {Screen} from "@/components/ignite"
import {sttModelManager as STT} from "@mentra/engine-host-internal"
import type {RemoteCatalogModel} from "@mentra/engine-host-internal"
import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

// The unsigned G2 IPA workflow is mobile/**-triggered but rebuilds the Captions
// miniapp from branch HEAD, so keep this host-side lab tied to that bundle path.

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
      return {label: "INITIALIZING · model loading off BLE thread", color: "#b989ff"}
    case "staged-relaunch":
      return {label: "STAGED · close/reopen G2 LABS to swap model", color: "#f0c36b"}
    case "failed":
      return {label: "FAILED · see error below", color: "#ff6b8a"}
    case "no-model":
      return {label: "NO MODEL LOADED", color: "#ff6b8a"}
    default:
      return {label: "UNKNOWN", color: "#8d809b"}
  }
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

  useEffect(() => {
    void STT.getCurrentLanguageFromPreferences().then((value) => value && setCurrent(value))
    void refreshDiagnostics()
    const timer = setInterval(() => {
      void refreshDiagnostics()
    }, 500)
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
  const appVersion = Application.nativeApplicationVersion || "3.1.2"

  const activate = async (code: string) => {
    try {
      setBusy(code)
      setProgress(0)
      setStatus("Preparing model…")
      const info = await STT.getLanguageInfo(code)
      if (!info.downloaded) {
        await STT.downloadModel(code, (p) => setProgress(p.percentage))
      }

      setStatus("Validating + loading model…")
      await STT.activateLanguage(code)
      setCurrent(code)

      const snapshot = await refreshDiagnostics()
      if (snapshot?.modelState === "ready") {
        setStatus("MODEL LIVE · open Captions and speak")
      } else if (snapshot?.modelState === "staged-relaunch") {
        setStatus("MODEL STAGED · fully close and reopen G2 LABS once to switch safely")
      } else if (snapshot?.modelState === "failed") {
        setStatus(snapshot.lastError || "Model initialization failed")
      } else {
        setStatus("Model selected · native runtime is finishing initialization")
      }
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
      setStatus("Extracting + validating custom Sherpa model…")

      const temp = `${RNFS.TemporaryDirectoryPath}/g2labs-custom-model.tar.bz2`
      if (await RNFS.exists(temp)) await RNFS.unlink(temp)
      const source = decodeURIComponent(asset.uri.replace("file://", ""))
      await RNFS.copyFile(source, temp)

      await STT.importCustomArchive(temp, "it-IT")
      setCurrent("custom")

      const snapshot = await refreshDiagnostics()
      if (snapshot?.modelState === "ready") {
        setStatus(`CUSTOM MODEL LIVE · ${asset.name}`)
      } else if (snapshot?.modelState === "staged-relaunch") {
        setStatus(`Custom selected · ${asset.name} · close/reopen once to switch safely`)
      } else {
        setStatus(`Custom selected · ${asset.name}`)
      }
      await RNFS.unlink(temp).catch(() => undefined)
    } catch (error: any) {
      setStatus(error?.message ?? "Custom import failed")
      await refreshDiagnostics()
    } finally {
      setBusy(null)
    }
  }

  const searchModelBrowser = async () => {
    try {
      setBrowserLoading(true)
      setBrowserError("")
      const models = await STT.browseRemoteModels(browserQuery)
      setBrowserModels(models)
      if (models.length === 0) setBrowserError("No models matched this search.")
    } catch (error: any) {
      setBrowserError(error?.message ?? "Could not load model sources")
    } finally {
      setBrowserLoading(false)
    }
  }

  const testRemoteModel = async (model: RemoteCatalogModel) => {
    if (!model.downloadUrl) {
      await Linking.openURL(model.sourceUrl)
      return
    }

    try {
      setBusy(`remote:${model.id}`)
      setProgress(0)
      setStatus(`QUARANTINE · downloading ${model.displayName}`)
      await STT.downloadAndTestCatalogModel(model, (p) => setProgress(p.percentage))
      setCurrent("custom")
      const snapshot = await refreshDiagnostics()
      if (snapshot?.modelState === "staged-relaunch") {
        setStatus(`SAFE TEST STAGED · ${model.displayName} · fully close/reopen once`)
      } else if (snapshot?.modelState === "ready") {
        setStatus(`REMOTE MODEL LIVE · ${model.displayName}`)
      } else {
        setStatus(`Model validated and staged · ${model.displayName}`)
      }
    } catch (error: any) {
      setStatus(error?.message ?? "Remote model test failed safely")
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

  const Card = ({code, title, sub}: {code: string; title: string; sub: string}) => (
    <Pressable
      onPress={() => void activate(code)}
      disabled={!!busy}
      style={{
        backgroundColor: "#15111d",
        borderWidth: 1,
        borderColor: current === code ? "#9b5cff" : "#30263d",
        borderRadius: 18,
        padding: 16,
        marginBottom: 12,
      }}>
      <RNText style={{color: "white", fontSize: 17, fontWeight: "700"}}>{title}</RNText>
      <RNText style={{color: "#a99db8", marginTop: 4}}>{sub}</RNText>
      <RNText
        style={{
          color: current === code ? "#b989ff" : "#766985",
          marginTop: 8,
          fontWeight: "600",
        }}>
        {busy === code
          ? progress > 0
            ? `Preparing… ${progress}%`
            : "Preparing…"
          : current === code
            ? "● SELECTED"
            : "Tap to download / activate"}
      </RNText>
    </Pressable>
  )

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
    <Screen preset="fixed" style={{backgroundColor: "#09070d"}}>
      <ScrollView contentContainerStyle={{padding: 22, paddingTop: 60, paddingBottom: 60}}>
        <Pressable onPress={() => router.back()}>
          <RNText style={{color: "#b989ff", fontSize: 16}}>‹ Back</RNText>
        </Pressable>

        <RNText style={{color: "white", fontSize: 32, fontWeight: "800", marginTop: 18}}>
          G2 MODEL LAB
        </RNText>
        <RNText style={{color: "#9b8cae", fontSize: 15, marginTop: 6, marginBottom: 24}}>
          Offline speech-engine lab · Italian · v{appVersion}
        </RNText>

        <Card code="it" title="Italian Built-in" sub="Known-good Kroko INT8 · recovery baseline" />
        <Card
          code="nemotron_it_80"
          title="Nemotron 3.5 · 80 ms ⚡ ULTRA"
          sub="Lowest-latency multilingual streaming preset"
        />
        <Card
          code="nemotron_it_160"
          title="Nemotron 3.5 · 160 ms ⚡ FAST"
          sub="Latency / accuracy balance"
        />

        <RNText style={{color: "#b989ff", fontSize: 14, fontWeight: "800", marginTop: 8, marginBottom: 10}}>
          CURATED DOWNLOADS · MULTILINGUAL NEMOTRON 3.5
        </RNText>
        <Card
          code="nemotron_it_320"
          title="Nemotron 3.5 · 320 ms · BALANCED"
          sub="More context than 160 ms · compare accuracy vs latency"
        />
        <Card
          code="nemotron_it_560"
          title="Nemotron 3.5 · 560 ms · ACCURACY"
          sub="Official Sherpa-ONNX multilingual export · stronger context"
        />
        <Card
          code="nemotron_it_1120"
          title="Nemotron 3.5 · 1120 ms · MAX CONTEXT"
          sub="Maximum context variant · likely slower first text, useful accuracy benchmark"
        />

        <View
          style={{
            backgroundColor: "#100d16",
            borderRadius: 18,
            padding: 16,
            marginBottom: 14,
            borderWidth: 1,
            borderColor: "#292032",
          }}>
          <RNText style={{color: "white", fontSize: 20, fontWeight: "800"}}>
            MODEL BROWSER
          </RNText>
          <RNText style={{color: "#a99db8", marginTop: 6, marginBottom: 12}}>
            Live Sherpa GitHub + Hugging Face discovery. Official Sherpa archives can be downloaded into quarantine and tested.
          </RNText>

          <TextInput
            value={browserQuery}
            onChangeText={setBrowserQuery}
            placeholder="Search: italian, streaming, parakeet, nemotron…"
            placeholderTextColor="#6f637c"
            autoCapitalize="none"
            autoCorrect={false}
            style={{
              color: "white",
              backgroundColor: "#17121e",
              borderWidth: 1,
              borderColor: "#392b49",
              borderRadius: 14,
              paddingHorizontal: 14,
              paddingVertical: 12,
            }}
          />
          <Pressable
            onPress={() => void searchModelBrowser()}
            disabled={browserLoading || !!busy}
            style={{
              backgroundColor: "#6d35a8",
              borderRadius: 14,
              padding: 13,
              marginTop: 10,
              alignItems: "center",
            }}>
            <RNText style={{color: "white", fontWeight: "800"}}>
              {browserLoading ? "SEARCHING SOURCES…" : "SEARCH ALL SOURCES"}
            </RNText>
          </Pressable>

          {!!browserError && (
            <RNText style={{color: "#ff829b", marginTop: 10, fontSize: 12}}>{browserError}</RNText>
          )}

          {browserModels.slice(0, 30).map((model) => {
            const direct = !!model.downloadUrl
            const badge =
              model.compatibility === "native-likely"
                ? "🟢 LIKELY NATIVE"
                : model.compatibility === "native-unverified"
                  ? "🟡 QUARANTINE TEST"
                  : "⚪ ADAPTER REQUIRED"

            return (
              <View
                key={model.id}
                style={{
                  marginTop: 12,
                  paddingTop: 12,
                  borderTopWidth: 1,
                  borderTopColor: "#292032",
                }}>
                <RNText style={{color: "white", fontWeight: "800"}}>{model.displayName}</RNText>
                <RNText style={{color: "#8f7fa3", marginTop: 3, fontSize: 12}}>
                  {model.source} · {badge}
                  {typeof model.size === "number" ? ` · ${STT.formatBytes(model.size)}` : ""}
                </RNText>
                <RNText style={{color: "#a99db8", marginTop: 5, fontSize: 12}}>{model.detail}</RNText>
                <View style={{flexDirection: "row", gap: 8, marginTop: 9}}>
                  <Pressable
                    onPress={() => void testRemoteModel(model)}
                    disabled={!!busy}
                    style={{
                      flex: 1,
                      backgroundColor: direct ? "#6d35a8" : "#21182b",
                      borderRadius: 11,
                      padding: 10,
                      alignItems: "center",
                    }}>
                    <RNText style={{color: "white", fontWeight: "800", fontSize: 12}}>
                      {busy === `remote:${model.id}`
                        ? progress > 0
                          ? `DOWNLOADING ${progress}%`
                          : "PREPARING…"
                        : direct
                          ? "DOWNLOAD & TEST"
                          : "OPEN MODEL"}
                    </RNText>
                  </Pressable>
                  <Pressable
                    onPress={() => void Linking.openURL(model.sourceUrl)}
                    style={{
                      backgroundColor: "#21182b",
                      borderRadius: 11,
                      padding: 10,
                      alignItems: "center",
                    }}>
                    <RNText style={{color: "#c8a6ff", fontWeight: "800", fontSize: 12}}>SOURCE ↗</RNText>
                  </Pressable>
                </View>
              </View>
            )
          })}
        </View>

        <View
          style={{
            backgroundColor: "#100d16",
            borderRadius: 18,
            padding: 16,
            marginBottom: 14,
            borderWidth: 1,
            borderColor: "#292032",
          }}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "800", marginBottom: 8}}>
            DISCOVERY SOURCES
          </RNText>
          <RNText style={{color: "#a99db8", marginBottom: 10}}>
            Broad model ecosystems and comparison feeds. Non-Sherpa families stay discovery-only until a runtime adapter exists.
          </RNText>
          {sourceLinks.map((source) => (
            <Pressable
              key={source.url}
              onPress={() => void Linking.openURL(source.url)}
              style={{
                paddingVertical: 11,
                borderTopWidth: 1,
                borderTopColor: "#292032",
              }}>
              <RNText style={{color: "#b989ff", fontWeight: "700"}}>{source.name} ↗</RNText>
              <RNText style={{color: "#766985", fontSize: 11, marginTop: 3}}>{source.detail}</RNText>
            </Pressable>
          ))}
        </View>

        <Pressable
          onPress={() => void importCustom()}
          disabled={!!busy}
          style={{
            backgroundColor: "#211332",
            borderWidth: 1,
            borderColor: "#9b5cff",
            borderRadius: 18,
            padding: 16,
            marginTop: 4,
          }}>
          <RNText style={{color: "white", fontSize: 17, fontWeight: "800"}}>
            ＋ Import Custom Sherpa Model
          </RNText>
          <RNText style={{color: "#bda8d6", marginTop: 5}}>
            .tar.bz2 · transducer or CTC · extracted + validated in-app
          </RNText>
        </Pressable>

        {busy && <ActivityIndicator style={{marginTop: 18}} color="#b989ff" />}
        <RNText style={{color: "#b989ff", marginTop: 14}}>{status}</RNText>

        <View
          style={{
            backgroundColor: "#100d16",
            borderRadius: 18,
            padding: 18,
            marginTop: 22,
            borderWidth: 1,
            borderColor: "#292032",
          }}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "800"}}>MODEL RUNTIME</RNText>
          <RNText style={{color: runtimeState.color, marginTop: 10, fontWeight: "800"}}>
            {runtimeState.label}
          </RNText>
          {!!diagnostics.lastError && (
            <RNText style={{color: "#ff829b", marginTop: 8, fontSize: 12}}>
              Last error: {diagnostics.lastError}
            </RNText>
          )}
        </View>

        <View
          style={{
            backgroundColor: "#100d16",
            borderRadius: 18,
            padding: 18,
            marginTop: 18,
            borderWidth: 1,
            borderColor: "#292032",
          }}>
          <View style={{flexDirection: "row", justifyContent: "space-between", alignItems: "center"}}>
            <RNText style={{color: "white", fontSize: 20, fontWeight: "800"}}>PIPELINE HEALTH</RNText>
            <Pressable onPress={() => void resetBenchmark()}>
              <RNText style={{color: "#b989ff", fontWeight: "700"}}>RESET</RNText>
            </Pressable>
          </View>

          {pipeline.map(([name, age]) => {
            const state = health(age)
            return (
              <View key={name} style={{flexDirection: "row", justifyContent: "space-between", paddingVertical: 7}}>
                <RNText style={{color: "#a99db8"}}>{name}</RNText>
                <RNText style={{color: state.color, fontWeight: "800"}}>{state.label}</RNText>
              </View>
            )
          })}
          <RNText style={{color: "#6f637c", fontSize: 12, marginTop: 10}}>
            Open Captions, speak for a few seconds, then return here. These stages persist for the whole app process.
          </RNText>
        </View>

        <View
          style={{
            backgroundColor: "#100d16",
            borderRadius: 18,
            padding: 18,
            marginTop: 18,
            borderWidth: 1,
            borderColor: "#292032",
          }}>
          <RNText style={{color: "white", fontSize: 20, fontWeight: "800", marginBottom: 14}}>
            LIVE BENCHMARK
          </RNText>
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
            <View key={key} style={{flexDirection: "row", justifyContent: "space-between", paddingVertical: 7}}>
              <RNText style={{color: "#a99db8"}}>{key}</RNText>
              <RNText style={{color: "white", fontWeight: "700"}}>{value}</RNText>
            </View>
          ))}
          <RNText style={{color: "#6f637c", fontSize: 12, marginTop: 10}}>
            No placeholders: values come from the persistent native G2/Sherpa pipeline.
          </RNText>
        </View>
      </ScrollView>
    </Screen>
  )
}
