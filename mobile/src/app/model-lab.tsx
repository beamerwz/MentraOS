import {useEffect, useMemo, useState} from "react"
import {ActivityIndicator, Pressable, ScrollView, Text as RNText, View} from "react-native"
import * as DocumentPicker from "expo-document-picker"
import RNFS from "@dr.pogodin/react-native-fs"
import {router} from "expo-router"

import {Screen} from "@/components/ignite"
import {sttModelManager as STT} from "@mentra/engine-host-internal"
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
          Offline speech-engine lab · Italian
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
