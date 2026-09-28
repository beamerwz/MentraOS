import {useRootNavigationState} from "expo-router"
import {useEffect, useRef} from "react"
import {ActivityIndicator, View} from "react-native"

import {DeviceTypes, SETTINGS, engine, useSetting} from "@mentra/engine"
import {G2LabsLogo} from "@/components/brands/G2LabsLogo"
import {Screen, Text} from "@/components/ignite"
import {useNavigationStore} from "@/stores/navigation"
import {ensureG2LabsEngineStarted} from "@/services/G2LabsBootstrap"

/**
 * Account-free G2 LABS boot. The engine must be configured and started before
 * the proven pairing screens call engine.pairing.scan().
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
      try {
        await ensureG2LabsEngineStarted()
      } catch (error) {
        console.error("G2LABS_BOOT bootstrap failed:", error)
      }

      const pairedWearable = engine.settings.get(SETTINGS.default_wearable.key) || defaultWearable
      if (pairedWearable === DeviceTypes.G2) {
        console.log("G2LABS_BOOT existing G2 pairing found -> home")
        clearHistoryAndGoHome({transition: "none"})
        return
      }

      console.log("G2LABS_BOOT fresh install -> G2 pairing")
      replace("/pairing/prep", {deviceModel: DeviceTypes.G2, onboarding: true, transition: "fade"})
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
