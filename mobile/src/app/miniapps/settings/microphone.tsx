import {Pressable, ScrollView, Text as RNText, View} from "react-native"

import {SETTINGS, useSetting} from "@mentra/engine"
import {DeviceTypes} from "@mentra/engine"
import {MicrophoneGateSettings} from "@/components/glasses/settings/MicrophoneGateSettings"
import {MicrophoneSelector} from "@/components/glasses/settings/MicrophoneSelector"
import {Icon, Screen} from "@/components/ignite"
import {useNavigationStore} from "@/stores/navigation"

export default function MicrophoneScreen() {
  const {goBack} = useNavigationStore.getState()
  const [defaultWearable] = useSetting(SETTINGS.default_wearable.key)
  const isMentraLive =
    defaultWearable === DeviceTypes.LIVE || String(defaultWearable || "").includes(DeviceTypes.LIVE)

  return (
    <Screen
      preset="fixed"
      safeAreaEdges={["top"]}
      backgroundColor="#050208"
      className="px-0"
      statusBarStyle="light">
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        showsVerticalScrollIndicator={false}
        contentContainerStyle={{paddingHorizontal: 22, paddingTop: 10, paddingBottom: 56}}>
        <View style={{flexDirection: "row", alignItems: "center", marginBottom: 28}}>
          <Pressable
            onPress={goBack}
            style={{
              width: 42,
              height: 42,
              borderRadius: 14,
              borderWidth: 1,
              borderColor: "#2D2039",
              backgroundColor: "#120D19",
              alignItems: "center",
              justifyContent: "center",
            }}>
            <Icon name="chevron-left" size={22} color="#C4B5FD" />
          </Pressable>
          <View style={{marginLeft: 14}}>
            <RNText style={{color: "white", fontSize: 27, fontWeight: "900"}}>Microphone</RNText>
            <RNText style={{color: "#7F708C", marginTop: 3, fontSize: 12}}>G2 Glasses audio source</RNText>
          </View>
        </View>

        <View
          style={{
            borderRadius: 24,
            borderWidth: 1,
            borderColor: "#2D2039",
            backgroundColor: "#0F0B14",
            padding: 16,
          }}>
          <MicrophoneSelector />
          {isMentraLive && (
            <View style={{marginTop: 18}}>
              <MicrophoneGateSettings />
            </View>
          )}
        </View>

        <View
          style={{
            marginTop: 18,
            borderRadius: 18,
            borderWidth: 1,
            borderColor: "#3A2550",
            backgroundColor: "#120A19",
            padding: 16,
          }}>
          <RNText style={{color: "#B989FF", fontSize: 12, fontWeight: "800"}}>G2 LABS TIP</RNText>
          <RNText style={{color: "#978AA4", fontSize: 13, lineHeight: 19, marginTop: 7}}>
            For the lowest-latency glasses captions, choose Glasses. Phone and Bluetooth remain available for testing.
          </RNText>
        </View>
      </ScrollView>
    </Screen>
  )
}
