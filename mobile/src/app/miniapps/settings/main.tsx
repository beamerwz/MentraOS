import * as Application from "expo-application"
import {Pressable, ScrollView, Text as RNText, View} from "react-native"

import {Icon, Screen} from "@/components/ignite"
import {DeviceSettingsSection} from "@/components/settings/DeviceSettingsSection"
import {RouteButton} from "@/components/ui/RouteButton"
import {useAppTheme} from "@/contexts/ThemeContext"
import {useNavigationStore} from "@/stores/navigation"

const PURPLE = "#A855F7"

export default function MainSettingsPage() {
  const {theme} = useAppTheme()
  const {goBack, push} = useNavigationStore.getState()
  const version = Application.nativeApplicationVersion || "3.1.3"

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
        contentContainerStyle={{paddingHorizontal: 22, paddingTop: 10, paddingBottom: 64}}>
        <View style={{flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginBottom: 28}}>
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

          <View style={{flex: 1, marginLeft: 14}}>
            <RNText style={{color: "white", fontSize: 28, fontWeight: "900"}}>G2 Settings</RNText>
            <RNText style={{color: "#7F708C", marginTop: 3, fontSize: 12}}>G2 Glasses · v{version}</RNText>
          </View>

          <View
            style={{
              paddingHorizontal: 10,
              paddingVertical: 6,
              borderRadius: 999,
              borderWidth: 1,
              borderColor: "#3B2850",
              backgroundColor: "#120D19",
            }}>
            <RNText style={{color: "#B989FF", fontSize: 11, fontWeight: "800"}}>G2 LABS</RNText>
          </View>
        </View>

        <View
          style={{
            borderRadius: 24,
            borderWidth: 1,
            borderColor: "#2D2039",
            backgroundColor: "#0F0B14",
            padding: 16,
            marginBottom: 24,
          }}>
          <RNText style={{color: "#8F7FA3", fontSize: 11, fontWeight: "900", letterSpacing: 1.3, marginBottom: 12}}>
            GLASSES
          </RNText>
          <DeviceSettingsSection />
        </View>

        <View
          style={{
            borderRadius: 24,
            borderWidth: 1,
            borderColor: "#2D2039",
            backgroundColor: "#0F0B14",
            padding: 14,
          }}>
          <RNText style={{color: "#8F7FA3", fontSize: 11, fontWeight: "900", letterSpacing: 1.3, margin: 4, marginBottom: 10}}>
            G2 GLASSES APP
          </RNText>

          <RouteButton
            icon={<Icon name="volume" size={24} color={theme.colors.secondary_foreground} />}
            label="Speech"
            onPress={() => push("/miniapps/settings/speech")}
          />
          <RouteButton
            icon={<Icon name="shield-lock" size={24} color={theme.colors.secondary_foreground} />}
            label="Privacy"
            onPress={() => push("/miniapps/settings/privacy")}
          />
        </View>

        <View
          style={{
            marginTop: 24,
            borderRadius: 18,
            borderWidth: 1,
            borderColor: "#382348",
            backgroundColor: "#120A19",
            padding: 16,
          }}>
          <RNText style={{color: "#B989FF", fontSize: 12, fontWeight: "800"}}>G2 LABS DARK PURPLE</RNText>
          <RNText style={{color: "#7F708C", marginTop: 5, fontSize: 12}}>
            Connection, microphone, display and device controls stay on the proven G2 runtime.
          </RNText>
        </View>

        <RNText style={{color: "#4E4358", textAlign: "center", marginTop: 34, fontSize: 10, letterSpacing: 1.2}}>
          G2 Glasses · v{version}
        </RNText>
      </ScrollView>
    </Screen>
  )
}
