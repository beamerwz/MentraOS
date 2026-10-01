import * as WebBrowser from "expo-web-browser"
import {Platform} from "react-native"

/** Returns false when the user cancels, so the caller can leave the sign-in screen. */
export async function openAuthBrowser(url: string, processUrl: (url: string) => Promise<void>): Promise<boolean> {
  const callbackUrl = "com.mentra://auth/callback"
  const isG2Labs = process.env.EXPO_PUBLIC_G2_LABS === "1"

  if (Platform.OS === "ios" && !isG2Labs) {
    const result = await WebBrowser.openBrowserAsync(url)
    return result.type === "dismiss"
  }

  // Core currently redirects OAuth to com.mentra://auth/callback. The G2 LABS
  // app itself uses g2glasses://, so ordinary Safari reports that callback as
  // an invalid address. ASWebAuthenticationSession owns the callback scheme
  // for this auth transaction and returns the URL to JS for PKCE completion.
  const result = await WebBrowser.openAuthSessionAsync(url, callbackUrl)
  if (result.type !== "success") return false

  await processUrl(result.url)
  return true
}
