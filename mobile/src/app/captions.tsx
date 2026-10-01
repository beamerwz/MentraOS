import {router} from "expo-router"
import {useEffect, useMemo, useState} from "react"
import {
  ActivityIndicator,
  Modal,
  Pressable,
  ScrollView,
  Text as RNText,
  View,
} from "react-native"

import LocalMiniappView from "@/components/miniapp/LocalMiniappView"
import {Screen} from "@/components/ignite"
import {useForegroundApps} from "@/hooks/useAppsExtras"
import {engine, useRefresh, useStart} from "@mentra/engine"
import {sttModelManager as STT} from "@mentra/engine-host-internal"
import type {CurrentModelSummary, InstalledModelEntry} from "@mentra/engine-host-internal"

const CAPTIONS_PACKAGE = "com.mentra.captions"
const PURPLE = "#A855F7"

const QUICK_MODELS = [
  {code: "it", title: "Italian Built-in · Kroko INT8"},
  {code: "nemotron_it_80", title: "Nemotron 3.5 · 80 ms"},
  {code: "nemotron_it_160", title: "Nemotron 3.5 · 160 ms"},
  {code: "nemotron_it_320", title: "Nemotron 3.5 · 320 ms"},
  {code: "nemotron_it_560", title: "Nemotron 3.5 · 560 ms"},
  {code: "nemotron_it_1120", title: "Nemotron 3.5 · 1120 ms"},
] as const

export default function G2IntegratedCaptions() {
  const apps = useForegroundApps()
  const refreshApps = useRefresh()
  const startApplet = useStart()
  const [ready, setReady] = useState(false)
  const [error, setError] = useState("")
  const [modelPickerOpen, setModelPickerOpen] = useState(false)
  const [modelBusy, setModelBusy] = useState<string | null>(null)
  const [currentModel, setCurrentModel] = useState<CurrentModelSummary>({
    code: "",
    displayName: "Loading model…",
    path: "",
    custom: false,
  })
  const [installedModels, setInstalledModels] = useState<InstalledModelEntry[]>([])

  const captionsApp = useMemo(
    () => apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE) ?? null,
    [apps],
  )

  const refreshModels = async () => {
    try {
      const [summary, installed] = await Promise.all([STT.getCurrentModelSummary(), STT.listInstalledModels()])
      setCurrentModel(summary)
      setInstalledModels(installed.filter((entry) => entry.runnable))
    } catch (e) {
      console.warn("G2 Captions: model refresh failed", e)
    }
  }

  useEffect(() => {
    void refreshModels()
  }, [])

  useEffect(() => {
    let alive = true
    const boot = async () => {
      try {
        await engine.miniapps.refresh()
        await refreshApps()
        const app = engine.miniapps.list().find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
        if (!app) {
          if (alive) setError("Captions is still preparing. Go back and try again.")
          return
        }
        if (!app.running) {
          const started = await startApplet(app, {skipNavigation: true})
          if (!started) throw new Error("Could not start the Captions runtime")
        }
        if (alive) setReady(true)
      } catch (e) {
        if (alive) setError(e instanceof Error ? e.message : String(e))
      }
    }
    void boot()
    return () => {
      alive = false
    }
  }, [refreshApps, startApplet])

  const selectPreset = async (code: string) => {
    try {
      setModelBusy(code)
      const info = await STT.getLanguageInfo(code)
      if (!info.downloaded) await STT.downloadModel(code)
      await STT.activateLanguage(code)
      await refreshModels()
      setModelPickerOpen(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setModelBusy(null)
    }
  }

  const selectInstalled = async (entry: InstalledModelEntry) => {
    try {
      setModelBusy(entry.id)
      await STT.activateInstalledModel(entry.path)
      await refreshModels()
      setModelPickerOpen(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setModelBusy(null)
    }
  }

  const app = captionsApp

  if (!ready || !app) {
    return (
      <Screen
        preset="fixed"
        safeAreaEdges={["top", "bottom"]}
        backgroundColor="#050208"
        className="px-0"
        statusBarStyle="light">
        <View style={{flex: 1, alignItems: "center", justifyContent: "center", padding: 28}}>
          {error ? (
            <>
              <RNText style={{color: "white", fontSize: 22, fontWeight: "900", textAlign: "center"}}>Captions</RNText>
              <RNText style={{color: "#9B8CAE", marginTop: 10, textAlign: "center"}}>{error}</RNText>
              <Pressable
                onPress={() => router.back()}
                style={{backgroundColor: "#6D35A8", borderRadius: 14, paddingHorizontal: 18, paddingVertical: 12, marginTop: 20}}>
                <RNText style={{color: "white", fontWeight: "800"}}>Back</RNText>
              </Pressable>
            </>
          ) : (
            <>
              <ActivityIndicator color="#C4B5FD" />
              <RNText style={{color: "#9B8CAE", marginTop: 12}}>Starting integrated G2 Captions…</RNText>
            </>
          )}
        </View>
      </Screen>
    )
  }

  return (
    <Screen
      preset="fixed"
      safeAreaEdges={["top"]}
      backgroundColor="#050208"
      className="px-0"
      statusBarStyle="light"
      KeyboardAvoidingViewProps={{enabled: false}}>
      <View
        style={{
          height: 58,
          paddingHorizontal: 16,
          flexDirection: "row",
          alignItems: "center",
          gap: 10,
          borderBottomWidth: 1,
          borderBottomColor: "#211728",
          backgroundColor: "#08040C",
        }}>
        <Pressable
          onPress={() => router.back()}
          style={{
            width: 38,
            height: 38,
            borderRadius: 13,
            alignItems: "center",
            justifyContent: "center",
            backgroundColor: "#15101B",
            borderWidth: 1,
            borderColor: "#2D2039",
          }}>
          <RNText style={{color: "#C4B5FD", fontSize: 24, marginTop: -2}}>‹</RNText>
        </Pressable>

        <View style={{flex: 1}}>
          <RNText style={{color: "white", fontSize: 18, fontWeight: "900"}}>Captions</RNText>
          <RNText style={{color: "#756981", fontSize: 10, marginTop: 1}}>G2 Glasses · on-device</RNText>
        </View>

        <Pressable
          onPress={() => {
            void refreshModels()
            setModelPickerOpen(true)
          }}
          style={{
            maxWidth: 178,
            borderRadius: 13,
            borderWidth: 1,
            borderColor: "#553071",
            backgroundColor: "#1A0E25",
            paddingHorizontal: 11,
            paddingVertical: 8,
          }}>
          <RNText style={{color: "#8F7FA3", fontSize: 9, fontWeight: "900"}}>MODEL</RNText>
          <RNText numberOfLines={1} style={{color: "#D8B4FE", fontSize: 11, fontWeight: "800", marginTop: 2}}>
            {currentModel.displayName}
          </RNText>
        </Pressable>
      </View>

      <View style={{flex: 1}}>
        <LocalMiniappView
          packageName={app.packageName}
          appName="G2 Captions"
          version={app.version}
          devUrl={app.devUrl}
          devPort={app.devPort != null ? String(app.devPort) : undefined}
          iconUrl={app.logoUrl}
          onExit={() => router.back()}
          showCapsule={false}
        />
      </View>

      <Modal
        visible={modelPickerOpen}
        transparent
        animationType="fade"
        onRequestClose={() => setModelPickerOpen(false)}>
        <Pressable
          onPress={() => setModelPickerOpen(false)}
          style={{flex: 1, backgroundColor: "rgba(0,0,0,0.62)", justifyContent: "flex-end"}}>
          <Pressable
            onPress={() => undefined}
            style={{
              maxHeight: "72%",
              backgroundColor: "#0B0710",
              borderTopLeftRadius: 28,
              borderTopRightRadius: 28,
              borderWidth: 1,
              borderColor: "#32213F",
              paddingTop: 18,
              paddingHorizontal: 18,
              paddingBottom: 30,
            }}>
            <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 14}}>
              <View>
                <RNText style={{color: "white", fontSize: 22, fontWeight: "900"}}>Speech model</RNText>
                <RNText style={{color: "#8F819B", fontSize: 12, marginTop: 3}}>Switch without leaving Captions</RNText>
              </View>
              <Pressable onPress={() => setModelPickerOpen(false)} style={{padding: 8}}>
                <RNText style={{color: "#C4B5FD", fontSize: 18}}>✕</RNText>
              </Pressable>
            </View>

            <ScrollView showsVerticalScrollIndicator={false}>
              {QUICK_MODELS.map((item, index) => {
                const active = currentModel.code === item.code
                return (
                  <Pressable
                    key={item.code}
                    disabled={!!modelBusy || active}
                    onPress={() => void selectPreset(item.code)}
                    style={{
                      paddingVertical: 13,
                      borderTopWidth: index === 0 ? 0 : 1,
                      borderTopColor: "#241A2D",
                      flexDirection: "row",
                      alignItems: "center",
                      gap: 10,
                    }}>
                    <View style={{flex: 1}}>
                      <RNText style={{color: "white", fontWeight: "800", fontSize: 14}}>{item.title}</RNText>
                    </View>
                    {modelBusy === item.code ? (
                      <ActivityIndicator color="#C4B5FD" />
                    ) : (
                      <RNText style={{color: active ? "#6FE3A5" : PURPLE, fontSize: 11, fontWeight: "900"}}>
                        {active ? "ACTIVE" : "USE"}
                      </RNText>
                    )}
                  </Pressable>
                )
              })}

              {installedModels.length > 0 && (
                <>
                  <RNText style={{color: "#8F7FA3", fontSize: 10, fontWeight: "900", letterSpacing: 1.2, marginTop: 18, marginBottom: 6}}>
                    MY MODELS
                  </RNText>
                  {installedModels.map((entry) => (
                    <Pressable
                      key={entry.path}
                      disabled={!!modelBusy || entry.current}
                      onPress={() => void selectInstalled(entry)}
                      style={{
                        paddingVertical: 12,
                        borderTopWidth: 1,
                        borderTopColor: "#241A2D",
                        flexDirection: "row",
                        alignItems: "center",
                        gap: 10,
                      }}>
                      <RNText numberOfLines={2} style={{color: "white", fontWeight: "800", fontSize: 13, flex: 1}}>
                        {entry.displayName}
                      </RNText>
                      {modelBusy === entry.id ? (
                        <ActivityIndicator color="#C4B5FD" />
                      ) : (
                        <RNText style={{color: entry.current ? "#6FE3A5" : PURPLE, fontSize: 11, fontWeight: "900"}}>
                          {entry.current ? "ACTIVE" : "USE"}
                        </RNText>
                      )}
                    </Pressable>
                  ))}
                </>
              )}

              <Pressable
                onPress={() => {
                  setModelPickerOpen(false)
                  router.push("/model-lab")
                }}
                style={{
                  marginTop: 18,
                  backgroundColor: "#1B1124",
                  borderRadius: 14,
                  borderWidth: 1,
                  borderColor: "#39284A",
                  padding: 12,
                  alignItems: "center",
                }}>
                <RNText style={{color: "#C4B5FD", fontWeight: "900", fontSize: 12}}>OPEN FULL MODEL LAB</RNText>
              </Pressable>
            </ScrollView>
          </Pressable>
        </Pressable>
      </Modal>
    </Screen>
  )
}
