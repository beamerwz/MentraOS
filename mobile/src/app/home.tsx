import {useFocusEffect} from "@react-navigation/native"
import {router} from "expo-router"
import {LinearGradient} from "expo-linear-gradient"
import * as Application from "expo-application"
import {useCallback, useEffect, useRef, useState, type ReactNode} from "react"
import {ActivityIndicator, Pressable, ScrollView, Text as RNText, View} from "react-native"
import {
  Activity,
  Bluetooth,
  Captions,
  ChevronRight,
  FlaskConical,
  Mic2,
  Settings,
  Sparkles,
} from "lucide-react-native"

import {G2LabsLogo} from "@/components/brands/G2LabsLogo"
import {GlassesStatus} from "@/components/home/DeviceStatus"
import {Screen} from "@/components/ignite"
import {attemptReconnectToDefaultWearable} from "@/effects/Reconnect"
import {useEngineSnapshot} from "@/hooks/useEngineSnapshot"
import {useForegroundApps} from "@/hooks/useAppsExtras"
import {BgTimer, engine, useRefresh, useSetForeground, useStart} from "@mentra/engine"

const PURPLE = "#A855F7"
const PURPLE_SOFT = "#C4B5FD"
const CARD = "#120D19"
const CARD_BORDER = "#2D2039"
const CAPTIONS_PACKAGE = "com.mentra.captions"

type QuickCardProps = {
  title: string
  subtitle: string
  icon: ReactNode
  onPress: () => void
  accent?: boolean
  wide?: boolean
}

function QuickCard({title, subtitle, icon, onPress, accent = false, wide = false}: QuickCardProps) {
  return (
    <Pressable
      onPress={onPress}
      style={({pressed}) => ({
        width: wide ? "100%" : "48.5%",
        minHeight: wide ? 116 : 150,
        borderRadius: 24,
        borderWidth: 1,
        borderColor: accent ? "#7C3AED" : CARD_BORDER,
        backgroundColor: pressed ? "#1C1027" : CARD,
        padding: 18,
        justifyContent: "space-between",
        transform: [{scale: pressed ? 0.985 : 1}],
      })}>
      <View
        style={{
          width: 44,
          height: 44,
          borderRadius: 15,
          backgroundColor: accent ? "#26113A" : "#1B1422",
          alignItems: "center",
          justifyContent: "center",
        }}>
        {icon}
      </View>
      <View style={{marginTop: 18}}>
        <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 8}}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "800", flex: 1}}>{title}</RNText>
          <ChevronRight size={18} color="#756581" />
        </View>
        <RNText style={{color: "#978AA4", fontSize: 13, lineHeight: 18, marginTop: 5}}>{subtitle}</RNText>
      </View>
    </Pressable>
  )
}

export default function G2LabsHome() {
  const refreshApps = useRefresh()
  const apps = useForegroundApps()
  const startApplet = useStart()
  const setForeground = useSetForeground()
  const [launchingCaptions, setLaunchingCaptions] = useState(false)
  const [launchMessage, setLaunchMessage] = useState("")
  const hasAttemptedInitialConnect = useRef(false)

  const glassesStatus = useEngineSnapshot(engine.glasses.status, (onChange) => engine.glasses.onStatus(onChange))
  const glassesConnected = glassesStatus.state === "connected"
  const battery =
    typeof glassesStatus.battery === "number" && glassesStatus.battery >= 0 ? glassesStatus.battery : null

  useFocusEffect(
    useCallback(() => {
      BgTimer.setTimeout(() => refreshApps(), 250)
    }, [refreshApps]),
  )

  useEffect(() => {
    const reconnect = async () => {
      if (hasAttemptedInitialConnect.current) return
      const attempted = await attemptReconnectToDefaultWearable()
      if (attempted) hasAttemptedInitialConnect.current = true
    }
    void reconnect()
  }, [glassesConnected])

  const launchCaptions = async () => {
    if (launchingCaptions) return
    setLaunchingCaptions(true)
    setLaunchMessage("")
    try {
      await engine.miniapps.refresh()
      const app = apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
      if (!app) {
        setLaunchMessage("Captions is still preparing. Try once more in a moment.")
        return
      }

      const started = app.running || (await startApplet(app, {skipNavigation: true}))
      if (!started) {
        setLaunchMessage("Captions could not start.")
        return
      }

      await setForeground(CAPTIONS_PACKAGE)
    } catch (error) {
      console.error("G2LABS_HOME captions launch failed", error)
      setLaunchMessage("Could not open Captions.")
    } finally {
      setLaunchingCaptions(false)
    }
  }

  const version = Application.nativeApplicationVersion || "3.1.2"

  return (
    <Screen preset="fixed" style={{backgroundColor: "#050208"}} KeyboardAvoidingViewProps={{enabled: false}}>
      <LinearGradient
        colors={["#050208", "#100619", "#08030D", "#050208"]}
        locations={[0, 0.28, 0.68, 1]}
        style={{position: "absolute", inset: 0}}
      />

      <View
        pointerEvents="none"
        style={{
          position: "absolute",
          width: 330,
          height: 330,
          borderRadius: 165,
          backgroundColor: "rgba(126, 34, 206, 0.11)",
          top: -110,
          right: -120,
        }}
      />
      <View
        pointerEvents="none"
        style={{
          position: "absolute",
          width: 250,
          height: 250,
          borderRadius: 125,
          backgroundColor: "rgba(168, 85, 247, 0.07)",
          top: 420,
          left: -130,
        }}
      />

      <ScrollView
        showsVerticalScrollIndicator={false}
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{paddingHorizontal: 22, paddingTop: 12, paddingBottom: 56}}>
        <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 26}}>
          <View style={{flexDirection: "row", alignItems: "center", gap: 12}}>
            <G2LabsLogo width={48} height={48} />
            <View>
              <RNText style={{color: "white", fontSize: 25, lineHeight: 28, fontWeight: "900", letterSpacing: 0.3}}>
                G2 LABS
              </RNText>
              <RNText style={{color: "#74677F", fontSize: 11, marginTop: 2, letterSpacing: 1.3}}>
                EXPERIMENTAL GLASSES ENGINE
              </RNText>
            </View>
          </View>
          <View
            style={{
              borderWidth: 1,
              borderColor: "#2B2034",
              backgroundColor: "#0C0910",
              borderRadius: 999,
              paddingHorizontal: 10,
              paddingVertical: 6,
            }}>
            <RNText style={{color: "#8D8099", fontSize: 11, fontWeight: "700"}}>v{version}</RNText>
          </View>
        </View>

        <LinearGradient
          colors={glassesConnected ? ["#1A0D27", "#100916"] : ["#130E18", "#0D0A11"]}
          start={{x: 0, y: 0}}
          end={{x: 1, y: 1}}
          style={{
            borderRadius: 28,
            borderWidth: 1,
            borderColor: glassesConnected ? "#5B2B7B" : "#302438",
            padding: 18,
            overflow: "hidden",
          }}>
          <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 13}}>
            <View>
              <RNText style={{color: "#806F90", fontSize: 11, fontWeight: "800", letterSpacing: 1.4}}>
                YOUR G2
              </RNText>
              <RNText style={{color: "white", fontSize: 24, fontWeight: "900", marginTop: 4}}>
                {glassesConnected ? "Connected" : "Ready to connect"}
              </RNText>
            </View>

            <View
              style={{
                flexDirection: "row",
                alignItems: "center",
                gap: 7,
                backgroundColor: glassesConnected ? "rgba(34,197,94,0.10)" : "rgba(168,85,247,0.10)",
                borderWidth: 1,
                borderColor: glassesConnected ? "rgba(74,222,128,0.28)" : "rgba(168,85,247,0.30)",
                borderRadius: 999,
                paddingHorizontal: 10,
                paddingVertical: 7,
              }}>
              <View
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: 4,
                  backgroundColor: glassesConnected ? "#4ADE80" : PURPLE,
                }}
              />
              <RNText
                style={{
                  color: glassesConnected ? "#86EFAC" : PURPLE_SOFT,
                  fontSize: 11,
                  fontWeight: "800",
                }}>
                {glassesConnected ? "LIVE" : "OFFLINE"}
              </RNText>
            </View>
          </View>

          <GlassesStatus />

          <View style={{flexDirection: "row", gap: 12, marginTop: 15}}>
            <View
              style={{
                flex: 1,
                borderRadius: 17,
                backgroundColor: "rgba(255,255,255,0.025)",
                borderWidth: 1,
                borderColor: "rgba(255,255,255,0.05)",
                padding: 12,
              }}>
              <View style={{flexDirection: "row", alignItems: "center", gap: 7}}>
                <Bluetooth size={15} color={glassesConnected ? "#4ADE80" : "#806F90"} />
                <RNText style={{color: "#756981", fontSize: 11, fontWeight: "700"}}>LINK</RNText>
              </View>
              <RNText style={{color: "white", fontSize: 15, fontWeight: "800", marginTop: 5}}>
                {glassesConnected ? "G2 active" : "Disconnected"}
              </RNText>
            </View>
            <View
              style={{
                flex: 1,
                borderRadius: 17,
                backgroundColor: "rgba(255,255,255,0.025)",
                borderWidth: 1,
                borderColor: "rgba(255,255,255,0.05)",
                padding: 12,
              }}>
              <View style={{flexDirection: "row", alignItems: "center", gap: 7}}>
                <Activity size={15} color={PURPLE_SOFT} />
                <RNText style={{color: "#756981", fontSize: 11, fontWeight: "700"}}>BATTERY</RNText>
              </View>
              <RNText style={{color: "white", fontSize: 15, fontWeight: "800", marginTop: 5}}>
                {battery === null ? "—" : `${battery}%`}
              </RNText>
            </View>
          </View>
        </LinearGradient>

        <View style={{flexDirection: "row", alignItems: "center", gap: 8, marginTop: 30, marginBottom: 14}}>
          <Sparkles size={16} color={PURPLE} />
          <RNText style={{color: "#B9A6C8", fontSize: 12, fontWeight: "900", letterSpacing: 1.3}}>G2 LABS</RNText>
        </View>

        <View style={{flexDirection: "row", flexWrap: "wrap", gap: 12}}>
          <QuickCard
            title="Captions"
            subtitle="Live G2 transcription"
            accent
            icon={launchingCaptions ? <ActivityIndicator color={PURPLE_SOFT} /> : <Captions size={24} color="#D8B4FE" />}
            onPress={() => void launchCaptions()}
          />
          <QuickCard
            title="Model Lab"
            subtitle="Models, browser & benchmark"
            icon={<FlaskConical size={24} color="#C084FC" />}
            onPress={() => router.push("/model-lab")}
          />
          <QuickCard
            title="Microphone"
            subtitle="G2 / phone audio source"
            icon={<Mic2 size={24} color="#C084FC" />}
            onPress={() => router.push("/miniapps/settings/microphone")}
          />
          <QuickCard
            title="Settings"
            subtitle="Connection & device controls"
            icon={<Settings size={24} color="#C084FC" />}
            onPress={() => router.push("/miniapps/settings/main")}
          />
        </View>

        {!!launchMessage && (
          <View
            style={{
              backgroundColor: "#170D20",
              borderWidth: 1,
              borderColor: "#4C2664",
              borderRadius: 16,
              padding: 13,
              marginTop: 14,
            }}>
            <RNText style={{color: "#D8B4FE", fontSize: 12}}>{launchMessage}</RNText>
          </View>
        )}

        <Pressable
          onPress={() => router.push("/model-lab")}
          style={({pressed}) => ({
            marginTop: 20,
            borderRadius: 24,
            borderWidth: 1,
            borderColor: "#32223F",
            backgroundColor: pressed ? "#17101F" : "#0F0B14",
            padding: 18,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "space-between",
          })}>
          <View style={{flex: 1}}>
            <RNText style={{color: "#7B6D87", fontSize: 11, fontWeight: "800", letterSpacing: 1.2}}>
              ENGINE STATUS
            </RNText>
            <RNText style={{color: "white", fontSize: 17, fontWeight: "800", marginTop: 5}}>Offline STT Lab</RNText>
            <RNText style={{color: "#8F819B", fontSize: 12, marginTop: 3}}>
              Benchmark latency, RTF, backlog and G2 display path.
            </RNText>
          </View>
          <View
            style={{
              width: 40,
              height: 40,
              borderRadius: 14,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: "#1C1126",
            }}>
            <Activity size={20} color={PURPLE} />
          </View>
        </Pressable>

        <View style={{alignItems: "center", marginTop: 34}}>
          <RNText style={{color: "#4F4558", fontSize: 10, fontWeight: "700", letterSpacing: 1.4}}>
            G2 LABS · DARK PURPLE · v{version}
          </RNText>
        </View>
      </ScrollView>
    </Screen>
  )
}
