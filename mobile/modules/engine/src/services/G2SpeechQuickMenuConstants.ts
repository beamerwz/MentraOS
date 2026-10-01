export const G2_SPEECH_MENU_PACKAGE = "com.g2labs.speech-control"
export const G2_SPEECH_MENU_NAME = "Captions"

export function isG2LabsSpeechMenuEnabled(): boolean {
  return process.env.EXPO_PUBLIC_G2_LABS === "1"
}
