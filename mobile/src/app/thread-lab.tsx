import {useEffect, useMemo, useState} from "react"
import {Pressable, ScrollView, Text as RNText, View} from "react-native"
import {router} from "expo-router"
import * as RNFS from "@dr.pogodin/react-native-fs"

import {Screen} from "@/components/ignite"
import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

type Diagnostics = {
  inferenceThreads?: number
  decodeRtf?: number
  speechToFirstPartialMs?: number
  speechToDisplayMs?: number
  partialIntervalMs?: number
  longestSpeechPartialGapMs?: number
  audioBacklogMs?: number
  queueDropCount?: number
}

type SavedSample = {
  threads: number
  savedAt: string
  decodeRtf: number | null
  speechToFirstPartialMs: number | null
  speechToDisplayMs: number | null
  partialIntervalMs: number | null
  longestSpeechPartialGapMs: number | null
  audioBacklogMs: number | null
  queueDropCount: number | null
}

const PURPLE = "#A855F7"
const SOFT = "#C4B5FD"
const CARD = "#100B16"
const BORDER = "#2D2039"
const RESULTS_FILE = `${RNFS.DocumentDirectoryPath}/g2-thread-lab-results.json`

function finite(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null
}

function show(value: number | null | undefined, suffix = "", decimals = 0) {
  if (value == null || !Number.isFinite(value) || value < 0) return "—"
  return `${value.toFixed(decimals)}${suffix}`
}

export default function ThreadPerformanceLab() {
  const [diagnostics, setDiagnostics] = useState<Diagnostics>({})
  const [stagedThreads, setStagedThreads] = useState(() => {
    try {
      return BluetoothSdk.getSttInferenceThreads()
    } catch {
      return 3
    }
  })
  const [samples, setSamples] = useState<Record<string, SavedSample>>({})
  const [message, setMessage] = useState("3 threads is the current GOLD baseline.")
  const [autoRunning, setAutoRunning] = useState(false)
  const [autoIndex, setAutoIndex] = useState(0)

  const autoThreads = [1, 2, 3, 4]

  useEffect(() => {
    void RNFS.readFile(RESULTS_FILE, "utf8")
      .then((raw) => setSamples(JSON.parse(raw) as Record<string, SavedSample>))
      .catch(() => undefined)

    const refresh = () => {
      try {
        setDiagnostics(BluetoothSdk.getG2LabDiagnostics() as Diagnostics)
      } catch {
        // Native diagnostics are best-effort; keep the last snapshot.
      }
    }
    refresh()
    const timer = setInterval(refresh, 500)
    return () => clearInterval(timer)
  }, [])

  const activeThreads = diagnostics.inferenceThreads ?? stagedThreads
  const activeSample = useMemo<SavedSample>(
    () => ({
      threads: activeThreads,
      savedAt: new Date().toISOString(),
      decodeRtf: finite(diagnostics.decodeRtf),
      speechToFirstPartialMs: finite(diagnostics.speechToFirstPartialMs),
      speechToDisplayMs: finite(diagnostics.speechToDisplayMs),
      partialIntervalMs: finite(diagnostics.partialIntervalMs),
      longestSpeechPartialGapMs: finite(diagnostics.longestSpeechPartialGapMs),
      audioBacklogMs: finite(diagnostics.audioBacklogMs),
      queueDropCount: finite(diagnostics.queueDropCount),
    }),
    [activeThreads, diagnostics],
  )

  const stageThreads = (threads: number) => {
    try {
      const applied = BluetoothSdk.setSttInferenceThreads(threads)
      setStagedThreads(applied)
      setMessage(
        applied === activeThreads
          ? `${applied} threads selected. This matches the active recognizer.`
          : `${applied} threads staged. Fully close and reopen G2 Glasses before benchmarking it.`,
      )
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error))
    }
  }

  const saveSample = async () => {
    const next = {...samples, [String(activeThreads)]: activeSample}
    setSamples(next)
    await RNFS.writeFile(RESULTS_FILE, JSON.stringify(next, null, 2), "utf8")
    setMessage(`Saved the current ${activeThreads}-thread result. Test the same phrase/conditions for each thread count.`)
  }

  const beginAutoTest = () => {
    setAutoRunning(true)
    setAutoIndex(0)
    stageThreads(autoThreads[0])
    setMessage("AUTO A/B started · 1 thread is staged. Restart G2 Glasses, run the same spoken test, then return here and tap SAVE + NEXT.")
  }

  const saveAndNext = async () => {
    await saveSample()
    const nextIndex = autoIndex + 1
    if (nextIndex >= autoThreads.length) {
      setAutoRunning(false)
      setMessage("AUTO A/B complete · results for 1 / 2 / 3 / 4 threads are saved below. Restore 3 threads unless another result is clearly better.")
      return
    }
    setAutoIndex(nextIndex)
    const nextThreads = autoThreads[nextIndex]
    stageThreads(nextThreads)
    setMessage(`Saved ${activeThreads} threads · ${nextThreads} threads staged. Restart, repeat the same phrase/conditions, then SAVE + NEXT.`)
  }

  return (
    <Screen preset="fixed" safeAreaEdges={["top"]} backgroundColor="#050208" className="px-0" statusBarStyle="light">
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={{paddingHorizontal: 20, paddingTop: 10, paddingBottom: 60}}>
        <Pressable onPress={() => router.back()} style={{paddingVertical: 8}}>
          <RNText style={{color: SOFT, fontSize: 16}}>‹ Model Lab</RNText>
        </Pressable>

        <RNText style={{color: "white", fontSize: 30, fontWeight: "900", marginTop: 8}}>Thread Performance</RNText>
        <RNText style={{color: "#8F819B", fontSize: 13, lineHeight: 19, marginTop: 6}}>
          A/B test Sherpa/ONNX inference threads on this iPhone. Thread changes are staged for the next app launch so the live recognizer is never rebuilt unsafely.
        </RNText>

        <View style={{backgroundColor: "#160C20", borderWidth: 1, borderColor: "#6D35A8", borderRadius: 20, padding: 16, marginTop: 20}}>
          <RNText style={{color: "#8F7FA3", fontSize: 10, fontWeight: "900", letterSpacing: 1.2}}>ACTIVE / NEXT LAUNCH</RNText>
          <RNText style={{color: "white", fontSize: 24, fontWeight: "900", marginTop: 7}}>
            {activeThreads} threads  →  {stagedThreads} threads
          </RNText>
          <RNText style={{color: activeThreads === stagedThreads ? "#6FE3A5" : "#F0C36B", fontSize: 12, marginTop: 6}}>
            {activeThreads === stagedThreads ? "Running selected configuration" : "Restart required before the staged value is active"}
          </RNText>
        </View>

        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: "#4D2A66", borderRadius: 20, padding: 16, marginTop: 18}}>
          <RNText style={{color: "white", fontSize: 17, fontWeight: "900"}}>AUTOMATIC 1 → 4 THREAD TEST</RNText>
          <RNText style={{color: "#8F819B", fontSize: 11, lineHeight: 17, marginTop: 5}}>
            Guides the same A/B run across every thread count while keeping each recognizer rebuild restart-safe.
          </RNText>
          <Pressable
            onPress={() => (autoRunning ? void saveAndNext() : beginAutoTest())}
            style={{backgroundColor: "#6D35A8", borderRadius: 13, padding: 12, alignItems: "center", marginTop: 12}}>
            <RNText style={{color: "white", fontWeight: "900"}}>
              {autoRunning ? `SAVE + NEXT · STEP ${autoIndex + 1}/4` : "START 1 / 2 / 3 / 4 TEST"}
            </RNText>
          </Pressable>
        </View>

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 24, marginBottom: 10}}>
          INFERENCE THREADS
        </RNText>
        <View style={{flexDirection: "row", gap: 8}}>
          {[1, 2, 3, 4].map((threads) => {
            const selected = stagedThreads === threads
            return (
              <Pressable
                key={threads}
                onPress={() => stageThreads(threads)}
                style={{
                  flex: 1,
                  alignItems: "center",
                  paddingVertical: 13,
                  borderRadius: 14,
                  borderWidth: 1,
                  borderColor: selected ? PURPLE : BORDER,
                  backgroundColor: selected ? "#251136" : CARD,
                }}>
                <RNText style={{color: "white", fontSize: 18, fontWeight: "900"}}>{threads}</RNText>
                <RNText style={{color: selected ? SOFT : "#756981", fontSize: 9, fontWeight: "800", marginTop: 3}}>
                  {threads === 3 ? "GOLD" : threads === 4 ? "ULTRA" : threads === 2 ? "BALANCED" : "BATTERY"}
                </RNText>
              </Pressable>
            )
          })}
        </View>

        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 16, marginTop: 18}}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "900"}}>LIVE RESULT · {activeThreads} THREADS</RNText>
          {[
            ["Decode RTF", show(finite(diagnostics.decodeRtf), "", 2)],
            ["Speech → first partial", show(finite(diagnostics.speechToFirstPartialMs), " ms")],
            ["Speech → G2 display", show(finite(diagnostics.speechToDisplayMs), " ms")],
            ["Partial interval", show(finite(diagnostics.partialIntervalMs), " ms")],
            ["Longest gap speaking", show(finite(diagnostics.longestSpeechPartialGapMs), " ms")],
            ["Audio backlog", show(finite(diagnostics.audioBacklogMs), " ms")],
            ["PCM queue drops", show(finite(diagnostics.queueDropCount))],
          ].map(([label, value]) => (
            <View key={label} style={{flexDirection: "row", justifyContent: "space-between", gap: 12, paddingVertical: 7}}>
              <RNText style={{color: "#A99DB8", flex: 1}}>{label}</RNText>
              <RNText style={{color: "white", fontWeight: "800"}}>{value}</RNText>
            </View>
          ))}

          <Pressable
            onPress={() => void saveSample()}
            style={{backgroundColor: "#6D35A8", borderRadius: 13, padding: 12, alignItems: "center", marginTop: 10}}>
            <RNText style={{color: "white", fontWeight: "900"}}>SAVE THIS RESULT</RNText>
          </Pressable>
        </View>

        <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.2, marginTop: 24, marginBottom: 10}}>
          SAVED A/B RESULTS
        </RNText>
        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, overflow: "hidden"}}>
          {[1, 2, 3, 4].map((threads, index) => {
            const sample = samples[String(threads)]
            return (
              <View
                key={threads}
                style={{padding: 14, borderTopWidth: index === 0 ? 0 : 1, borderTopColor: "#241A2D"}}>
                <View style={{flexDirection: "row", justifyContent: "space-between", alignItems: "center"}}>
                  <RNText style={{color: "white", fontWeight: "900"}}>{threads} THREAD{threads === 1 ? "" : "S"}</RNText>
                  <RNText style={{color: sample ? "#6FE3A5" : "#756981", fontSize: 10, fontWeight: "900"}}>
                    {sample ? "SAVED" : "NO SAMPLE"}
                  </RNText>
                </View>
                {sample ? (
                  <RNText style={{color: "#8F819B", fontSize: 11, lineHeight: 17, marginTop: 5}}>
                    RTF {show(sample.decodeRtf, "", 2)} · G2 {show(sample.speechToDisplayMs, " ms")} · partial {show(sample.partialIntervalMs, " ms")} · longest gap {show(sample.longestSpeechPartialGapMs, " ms")}
                  </RNText>
                ) : (
                  <RNText style={{color: "#665B70", fontSize: 11, marginTop: 5}}>Run Captions, speak, then save a comparable sample.</RNText>
                )}
              </View>
            )
          })}
        </View>

        <RNText style={{color: SOFT, fontSize: 12, lineHeight: 18, marginTop: 16}}>{message}</RNText>
      </ScrollView>
    </Screen>
  )
}
