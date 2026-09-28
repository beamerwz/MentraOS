import {useLocalSearchParams} from "expo-router"
import {useEffect} from "react"
import {TouchableOpacity, View} from "react-native"
import {focusEffectPreventBack} from "@/contexts/NavigationHistoryContext"
import {useNavigationStore} from "@/stores/navigation"

import {Button, Icon, Text, Screen} from "@/components/ignite"
import {useAppTheme} from "@/contexts/ThemeContext"
import {translate} from "@/i18n"
import showAlert from "@/utils/AlertUtils"
import mentraAuth from "@/utils/auth/authClient"
import {mapAuthError} from "@/utils/auth/authErrors"
import {G2LabsLogo} from "@/components/brands/G2LabsLogo"

export default function LoginScreen() {
  const {push, replace, setAnimation} = useNavigationStore.getState()
  const {authError} = useLocalSearchParams<{authError?: string}>()
  const {theme} = useAppTheme()

  focusEffectPreventBack()

  // Handle auth errors passed via URL params (e.g., from expired reset links)
  useEffect(() => {
    if (authError) {
      const errorMessage = mapAuthError(authError)
      showAlert(translate("common:error"), errorMessage, [{text: translate("common:ok")}])
    }
  }, [authError])

  const handleWebLogin = async (url: string) => {
    console.log("Opening browser with:", url)
    setAnimation("fade")
    await new Promise((resolve) => setTimeout(resolve, 1))
    push("/auth/web-splash", {url})
    // await new Promise((resolve) => setTimeout(resolve, 1000))
    // await WebBrowser.openBrowserAsync(url)
  }

  const handleSignup = async () => {
    setAnimation("simple_push")
    await new Promise((resolve) => setTimeout(resolve, 1))
    push("/auth/signup")
  }

  return (
    <Screen preset="fixed">
      <View className="flex-1">
        <View className="flex-1 justify-center p-4">
          <View className="items-center justify-center mb-4">
            <G2LabsLogo width={86} height={86} />
          </View>

          <Text
            text="G2 LABS"
            className="text-[46px] text-primary-foreground text-secondary-foreground text-center mb-2 pt-8 pb-4"
          />

          <Text className="text-base text-secondary-foreground text-center text-xl mb-4">
            Fast, private captions for your G2.
          </Text>

          <View className="mb-4">
            <View className="gap-4">
              <Button
                preset="primary"
                text={translate("login:signUpWithEmail")}
                onPress={handleSignup}
                LeftAccessory={() => <Icon name="mail" size={20} color={theme.colors.background} />}
              />
                  onPress={handleAppleSignIn}
                  LeftAccessory={() => <AppleIcon color={theme.colors.foreground} />}
                />
              )}
            </View>
          </View>

          {/* Already have an account? Log in */}
          <View className="flex-row justify-center items-center gap-1 mt-2">
            <Text className="text-sm text-muted-foreground">{translate("login:alreadyHaveAccount")}</Text>
            <TouchableOpacity onPress={() => push("/auth/email-login")}>
              <Text className="text-sm text-secondary-foreground font-semibold">{translate("login:logIn")}</Text>
            </TouchableOpacity>
          </View>

          <Text className="text-[11px] text-muted-foreground text-center mt-2">{translate("login:termsText")}</Text>
        </View>
      </View>
    </Screen>
  )
}
