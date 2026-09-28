import {useLocalSearchParams} from "expo-router"
import {useEffect} from "react"
import {TouchableOpacity, View} from "react-native"

import {G2LabsLogo} from "@/components/brands/G2LabsLogo"
import {Button, Icon, Screen, Text} from "@/components/ignite"
import {focusEffectPreventBack} from "@/contexts/NavigationHistoryContext"
import {useAppTheme} from "@/contexts/ThemeContext"
import {translate} from "@/i18n"
import {useNavigationStore} from "@/stores/navigation"
import showAlert from "@/utils/AlertUtils"
import {mapAuthError} from "@/utils/auth/authErrors"

export default function LoginScreen() {
  const {push, setAnimation} = useNavigationStore.getState()
  const {authError} = useLocalSearchParams<{authError?: string}>()
  const {theme} = useAppTheme()

  focusEffectPreventBack()

  useEffect(() => {
    if (authError) {
      const errorMessage = mapAuthError(authError)
      showAlert(translate("common:error"), errorMessage, [{text: translate("common:ok")}])
    }
  }, [authError])

  const handleSignup = async () => {
    setAnimation("simple_push")
    await new Promise((resolve) => setTimeout(resolve, 1))
    push("/auth/signup")
  }

  return (
    <Screen preset="fixed">
      <View className="flex-1 bg-black">
        <View className="flex-1 justify-center p-6">
          <View className="items-center justify-center mb-2">
            <G2LabsLogo width={92} height={92} />
          </View>

          <Text text="G2 LABS" className="text-[44px] text-white text-center font-bold mt-4" />
          <Text className="text-base text-center text-[#C4B5FD] text-lg mt-2 mb-8">
            Fast, private captions for your G2.
          </Text>

          <View className="gap-4">
            <Button
              preset="primary"
              text="Continue with email"
              onPress={handleSignup}
              LeftAccessory={() => <Icon name="mail" size={20} color={theme.colors.background} />}
            />
          </View>

          <View className="flex-row justify-center items-center gap-1 mt-5">
            <Text className="text-sm text-[#A1A1AA]">Already have an account?</Text>
            <TouchableOpacity onPress={() => push("/auth/email-login")}>
              <Text className="text-sm text-[#C084FC] font-semibold">Log in</Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>
    </Screen>
  )
}
