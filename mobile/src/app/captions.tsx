import {router} from "expo-router"
import {useEffect, useMemo, useState} from "react"
import {ActivityIndicator, Pressable, Text as RNText, View} from "react-native"

import LocalMiniappView from "@/components/miniapp/LocalMiniappView"
import {Screen} from "@/components/ignite"
import {useForegroundApps} from "@/hooks/useAppsExtras"
import {engine, useRefresh, useStart} from "@mentra/engine"

const CAPTIONS_PACKAGE = "com.mentra.captions"

export default function G2IntegratedCaptions() {
  const apps = useForegroundApps()
  const refreshApps = useRefresh()
  const startApplet = useStart()
  const [ready, setReady] = useState(false)
  const [error, setError] = useState("")

  const captionsApp = useMemo(
    () => apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE) ?? null,
    [apps],
  )

  useEffect(() => {
    let alive = true
    const boot = async () => {
      try {
        await engine.miniapps.refresh()
        await refreshApps()
        const app = engine.miniapps.getSnapshot().apps.find((candidate) => candidate.packageName === CAPTIONS_PACKAGE)
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
      safeAreaEdges={[]}
      backgroundColor="#050208"
      className="px-0"
      statusBarStyle="light"
      KeyboardAvoidingViewProps={{enabled: false}}>
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
    </Screen>
  )
}
