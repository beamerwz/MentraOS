import {useEffect, useMemo, useRef, useState} from "react"
import {Pressable, ScrollView, Text as RNText, View} from "react-native"
import {router} from "expo-router"
import {
  useSpeechToText,
  WHISPER_TINY,
  WHISPER_BASE,
  WHISPER_SMALL,
} from "react-native-executorch"

import {Screen} from "@/components/ignite"
import BluetoothSdk from "@mentra/bluetooth-sdk/internal"

const PURPLE = "#A855F7"
const SOFT = "#C4B5FD"
const CARD = "#100B16"
const BORDER = "#2D2039"

type WhisperChoice = "tiny" | "base" | "small"

function pcm16ToFloat32(input: ArrayBuffer): Float32Array {
  const view = new DataView(input)
  const samples = new Float32Array(Math.floor(input.byteLength / 2))
  for (let i = 0; i < samples.length; i += 1) {
    samples[i] = view.getInt16(i * 2, true) / 32768
  }
  return samples
}

export default function RuntimeLab() {
  const [choice, setChoice] = useState<WhisperChoice>("tiny")
  const [running, setRunning] = useState(false)
  const [message, setMessage] = useState("Choose a Whisper model, wait for READY, then test it with the G2 microphone.")
  const pcmSubscription = useRef<{remove: () => void} | null>(null)

  const model = useMemo(() => {
    if (choice === "base") return WHISPER_BASE
    if (choice === "small") return WHISPER_SMALL
    return WHISPER_TINY
  }, [choice])

  const whisper = useSpeechToText({model, preventLoad: false})

  const stop = () => {
    pcmSubscription.current?.remove()
    pcmSubscription.current = null
    try {
      whisper.streamStop()
    } catch {
      // A stopped/not-yet-started stream is harmless.
    }
    setRunning(false)
    setMessage("Whisper test stopped.")
  }

  useEffect(() => {
    return () => {
      pcmSubscription.current?.remove()
      pcmSubscription.current = null
      try {
        whisper.streamStop()
      } catch {}
    }
  }, [whisper])

  const start = async () => {
    if (!whisper.isReady || running) return
    try {
      setRunning(true)
      setMessage("Starting ExecuTorch Whisper on the G2 PCM stream…")
      await BluetoothSdk.updateBluetoothSettings({should_send_pcm: true})

      const streamPromise = whisper.stream({language: "it"})
      pcmSubscription.current = BluetoothSdk.addListener("mic_pcm", (event) => {
        try {
          whisper.streamInsert(pcm16ToFloat32(event.pcm))
        } catch {
          // The first packet can race stream initialization; later packets continue normally.
        }
      })
      void streamPromise
        .then(() => {
          setRunning(false)
          setMessage("Whisper stream finished.")
        })
        .catch((error) => {
          setRunning(false)
          setMessage(error instanceof Error ? error.message : String(error))
        })
    } catch (error) {
      setRunning(false)
      setMessage(error instanceof Error ? error.message : String(error))
    }
  }

  return (
    <Screen preset="fixed" safeAreaEdges={["top"]} backgroundColor="#050208" className="px-0" statusBarStyle="light">
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={{paddingHorizontal: 20, paddingTop: 10, paddingBottom: 60}}>
        <Pressable onPress={() => router.back()} style={{paddingVertical: 8}}>
          <RNText style={{color: SOFT, fontSize: 16}}>‹ Model Lab</RNText>
        </Pressable>

        <RNText style={{color: "white", fontSize: 30, fontWeight: "900", marginTop: 8}}>Voice Runtime Lab</RNText>
        <RNText style={{color: "#8F819B", fontSize: 13, lineHeight: 19, marginTop: 6}}>
          Native engines bundled into this IPA. Sherpa-ONNX powers normal G2 Captions; ExecuTorch lets us test multilingual Whisper directly on the same 16 kHz G2 PCM stream.
        </RNText>

        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 16, marginTop: 20}}>
          <View style={{flexDirection: "row", justifyContent: "space-between", alignItems: "center"}}>
            <View>
              <RNText style={{color: "white", fontSize: 17, fontWeight: "900"}}>Sherpa-ONNX</RNText>
              <RNText style={{color: "#8F819B", fontSize: 11, marginTop: 4}}>Streaming Transducer + CTC · G2 Captions engine</RNText>
            </View>
            <RNText style={{color: "#6FE3A5", fontSize: 10, fontWeight: "900"}}>BUILT IN · LIVE</RNText>
          </View>
        </View>

        <View style={{backgroundColor: CARD, borderWidth: 1, borderColor: BORDER, borderRadius: 20, padding: 16, marginTop: 12}}>
          <View style={{flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 10}}>
            <View style={{flex: 1}}>
              <RNText style={{color: "white", fontSize: 17, fontWeight: "900"}}>ExecuTorch · Whisper</RNText>
              <RNText style={{color: "#8F819B", fontSize: 11, marginTop: 4}}>Multilingual Tiny / Base / Small · native iOS runtime</RNText>
            </View>
            <RNText style={{color: whisper.isReady ? "#6FE3A5" : SOFT, fontSize: 10, fontWeight: "900"}}>
              {whisper.isReady ? "READY" : `LOADING ${Math.round(whisper.downloadProgress)}%`}
            </RNText>
          </View>

          <View style={{flexDirection: "row", gap: 8, marginTop: 14}}>
            {(["tiny", "base", "small"] as WhisperChoice[]).map((item) => (
              <Pressable
                key={item}
                disabled={running}
                onPress={() => setChoice(item)}
                style={{
                  flex: 1,
                  borderRadius: 12,
                  borderWidth: 1,
                  borderColor: choice === item ? PURPLE : BORDER,
                  backgroundColor: choice === item ? "#251136" : "#17121E",
                  paddingVertical: 11,
                  alignItems: "center",
                  opacity: running ? 0.55 : 1,
                }}>
                <RNText style={{color: "white", fontWeight: "900", textTransform: "uppercase"}}>{item}</RNText>
              </Pressable>
            ))}
          </View>

          {whisper.error ? (
            <RNText style={{color: "#FF829B", fontSize: 11, lineHeight: 16, marginTop: 12}}>{whisper.error.message}</RNText>
          ) : null}

          <Pressable
            disabled={!whisper.isReady}
            onPress={() => (running ? stop() : void start())}
            style={{
              backgroundColor: running ? "#32111C" : "#6D35A8",
              borderRadius: 13,
              padding: 12,
              alignItems: "center",
              marginTop: 14,
              opacity: whisper.isReady ? 1 : 0.45,
            }}>
            <RNText style={{color: "white", fontWeight: "900"}}>{running ? "STOP G2 WHISPER TEST" : "START G2 WHISPER TEST"}</RNText>
          </Pressable>

          <RNText style={{color: "#8F819B", fontSize: 11, lineHeight: 17, marginTop: 12}}>
            {message}
          </RNText>

          <View style={{backgroundColor: "#08060B", borderRadius: 14, padding: 13, marginTop: 12, minHeight: 120}}>
            <RNText style={{color: "#756981", fontSize: 10, fontWeight: "900", letterSpacing: 1}}>LIVE WHISPER TEXT</RNText>
            <RNText style={{color: "white", fontSize: 16, lineHeight: 23, marginTop: 8}}>
              {whisper.committedTranscription}
              <RNText style={{color: SOFT}}>{whisper.nonCommittedTranscription}</RNText>
            </RNText>
          </View>
        </View>

        <View style={{backgroundColor: "#140D18", borderWidth: 1, borderColor: "#34253D", borderRadius: 18, padding: 14, marginTop: 16}}>
          <RNText style={{color: "#F0C36B", fontSize: 11, fontWeight: "900"}}>VOSK · NOT BUNDLED ON iOS</RNText>
          <RNText style={{color: "#8F819B", fontSize: 11, lineHeight: 17, marginTop: 6}}>
            G2 Glasses will not pretend Vosk is installed. The upstream project currently does not publish a maintained iOS library artifact we can safely embed in this build. Vosk models are therefore excluded from the compatible catalog.
          </RNText>
        </View>
      </ScrollView>
    </Screen>
  )
}
