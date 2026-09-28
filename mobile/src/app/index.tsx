import {useRootNavigationState} from "expo-router"
import {useEffect, useRef} from "react"
import {ActivityIndicator, View} from "react-native"

import {DeviceTypes, SETTINGS, engine, useSetting} from "@mentra/engine"
import {cloudConfigValues} from "@/services/cloudClient"
import {G2LabsLogo} from "@/components/brands/G2LabsLogo"
import {Screen, Text} from "@/components/ignite"
import {useNavigationStore} from "@/stores/navigation"
import {ensureG2LabsEngineStarted} from "@/services/G2LabsBootstrap"

/**
 * G2 LABS local boot.
 *
 * Deliberately does not enter Mentra account/cloud authentication.  Pairing,
 * reconnect, settings and the native G2 transport remain owned by the existing
 * engine.  On a fresh install we enter the proven G2 prep/pairing flow directly.
 */
export default function G2LabsInitScreen() {
  const rootNavigationState = useRootNavigationState()
  const {replace, clearHistoryAndGoHome} = useNavigationStore.getState()
  const [defaultWearable] = useSetting(SETTINGS.default_wearable.key)
  const routed = useRef(false)

  useEffect(() => {
    if (!rootNavigationState?.key || routed.current) return
    routed.current = true

    const boot = async () => {
      // The original Mentra boot called MantleManager.init(), whose critical
      // hardware side effect is engine.configure()+engine.start().  Auth was
      // removed from G2 LABS, but skipping engine.start() also skipped native
      // device-store hydration + Bluetooth status/event projection.  Pairing
      // then rendered correctly while scanning against an unbootstrapped host.
      //
      // G2 LABS supplies a local/offline auth seam. Cloud calls may fail closed,
      // but the engine hardware runtime is fully started exactly as pairing expects.
      engine.configure({
        auth: {
          getSubjectToken: async () => {
            throw new Error("G2 LABS offline mode: cloud authentication disabled")
          },
        },
        config: cloudConfigValues(),
      })
      try {
        await engine.start()
        console.log("G2LABS_BOOT engine started")
      } catch (error) {
        // Hardware startup intentionally survives unavailable cloud/auth.
        console.warn("G2LABS_BOOT engine start warning", error)
      }

      const pairedWearable = engine.settings.get(SETTINGS.default_wearable.key) || defaultWearable
      if (pairedWearable === DeviceTypes.G2) {
        console.log("G2LABS_BOOT existing G2 pairing found -> home")
        clearHistoryAndGoHome({transition: "none"})
        return
      }

      console.log("G2LABS_BOOT fresh install -> G2 pairing")
      replace("/pairing/prep", {deviceModel: DeviceTypes.G2, onboarding: true, transition: "fade"})
      } catch (error) {
        console.error("G2LABS_BOOT bootstrap failed:", error)
        // Keep first launch recoverable: pairing permissions/native scan may
        // still work even if an optional engine service failed to initialize.
        replace("/pairing/prep", {deviceModel: DeviceTypes.G2, onboarding: true, transition: "fade"})
      }
    }

    void boot()
  }, [rootNavigationState?.key, defaultWearable, replace, clearHistoryAndGoHome])

  return (
    <Screen preset="fixed">
      <View className="flex-1 bg-black items-center justify-center">
        <G2LabsLogo width={92} height={92} />
        <Text text="G2 LABS" className="text-white text-3xl font-bold mt-5" />
        <Text text="Preparing your G2…" className="text-[#C4B5FD] text-base mt-2" />
        <ActivityIndicator size="small" color="#A855F7" className="mt-6" />
      </View>
    </Screen>
  )
}
