import {useRootNavigationState} from "expo-router"
import {useEffect, useRef} from "react"
import {ActivityIndicator, View} from "react-native"

import {DeviceTypes, SETTINGS, engine, useSetting} from "@mentra/engine"
import {G2LabsLogo} from "@/components/brands/G2LabsLogo"
import {Screen, Text} from "@/components/ignite"
import {useNavigationStore} from "@/stores/navigation"

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
      // Give the settings/native engine one tick to finish hydration.
      await new Promise((resolve) => setTimeout(resolve, 120))

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
