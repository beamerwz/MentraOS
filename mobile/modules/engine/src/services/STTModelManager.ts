import BluetoothSdk from "@mentra/bluetooth-sdk"
import {Platform} from "react-native"
import * as RNFS from "@dr.pogodin/react-native-fs"

export interface LanguageInfo {
  code: string
  displayName: string
  size: number
  language: string
  downloaded: boolean
  path?: string
  type: "transducer" | "ctc"
}

export interface DownloadProgress {
  jobId: number
  bytesWritten: number
  contentLength: number
  percentage: number
}

export interface ExtractionProgress {
  percentage: number
  currentFile?: string
}

export interface DirectModelFile {
  fileName: string
  url: string
  size?: number
}

export type ModelCompatibility = "native-likely" | "native-unverified" | "adapter-required"
export type ModelRuntime = "sherpa-onnx" | "whisper.cpp" | "vosk" | "funasr" | "unknown"
export type ModelDownloadMode = "test" | "store"

export interface RemoteCatalogModel {
  id: string
  displayName: string
  source: string
  sourceUrl: string
  downloadUrl?: string
  directFiles?: DirectModelFile[]
  fileName?: string
  size?: number
  languageCode: string
  compatibility: ModelCompatibility
  runtime: ModelRuntime
  downloadMode: ModelDownloadMode
  detail: string
  tags: string[]
}

export interface CurrentModelSummary {
  code: string
  displayName: string
  path: string
  custom: boolean
  source?: string
}

export interface InstalledModelEntry {
  id: string
  displayName: string
  path: string
  source: string
  sourceUrl?: string
  runtime: ModelRuntime
  languageCode: string
  runnable: boolean
  current: boolean
  installedAt?: string
}

export interface ModelSourceLink {
  name: string
  url: string
  detail: string
}

export interface LanguageConfig {
  code: string
  displayName: string
  fileName: string
  downloadUrl?: string
  directFiles?: DirectModelFile[]
  size: number
  type: "transducer" | "ctc"
  requiredFiles: string[]
  languageCode: string
  archiveSha256?: string
  experimental?: boolean
}

const DEFAULT_LANGUAGE = "en"
const NEMOTRON_MARKER = ".g2labs-nemotron-v2"
const CUSTOM_METADATA = ".g2labs-model.json"

class STTModelManager {
  private static instance: STTModelManager
  private downloadJobId?: number
  private currentLanguage = DEFAULT_LANGUAGE
  private modelBaseUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"

  private readonly modelSourceLinks: ModelSourceLink[] = [
    {
      name: "Sherpa-ONNX · Recommended",
      url: "https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html",
      detail: "Primary source for models most likely to run directly in G2 Glasses.",
    },
    {
      name: "Sherpa-ONNX · Direct releases",
      url: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models",
      detail: "Official downloadable .tar.bz2 ASR packages.",
    },
    {
      name: "Hugging Face · ASR models",
      url: "https://huggingface.co/models?pipeline_tag=automatic-speech-recognition&sort=trending",
      detail: "Largest discovery source; Search V2 inspects downloadable files automatically.",
    },
    {
      name: "Hugging Face · Open ASR Leaderboard",
      url: "https://huggingface.co/spaces/hf-audio/open_asr_leaderboard",
      detail: "Useful accuracy / WER / speed comparison reference.",
    },
    {
      name: "whisper.cpp · On-device models",
      url: "https://github.com/ggml-org/whisper.cpp/tree/master/models",
      detail: "Direct-download Whisper models for the future native runtime adapter.",
    },
    {
      name: "Vosk · Lightweight offline models",
      url: "https://alphacephei.com/vosk/models",
      detail: "Very small offline models, including Italian.",
    },
    {
      name: "Gladia · Open STT overview",
      url: "https://www.gladia.io/blog/best-open-source-speech-to-text-models",
      detail: "Curated overview of strong modern open speech-recognition families.",
    },
  ]

  private languages: Record<string, LanguageConfig> = {
    en: {
      code: "en",
      displayName: "English",
      fileName: "sherpa-onnx-streaming-zipformer-en-2023-06-21-mobile",
      size: 349 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "en-US",
    },
    fr: {
      code: "fr",
      displayName: "Français",
      fileName: "sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06",
      size: 57 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "fr-FR",
    },
    de: {
      code: "de",
      displayName: "Deutsch",
      fileName: "sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06",
      size: 58 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "de-DE",
    },
    es: {
      code: "es",
      displayName: "Español",
      fileName: "sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06",
      size: 124 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "es-ES",
    },
    it: {
      code: "it",
      displayName: "Italiano",
      fileName: "kroko_64l_it_int8",
      size: 154 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it-IT",
      directFiles: [
        {
          fileName: "encoder.int8.onnx",
          url: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/encoder.int8.onnx",
        },
        {
          fileName: "decoder.int8.onnx",
          url: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/decoder.int8.onnx",
        },
        {
          fileName: "joiner.int8.onnx",
          url: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/joiner.int8.onnx",
        },
        {
          fileName: "tokens.txt",
          url: "https://huggingface.co/hudaiapa88/sherpa-stt-onnx/resolve/main/it/kroko_64l/tokens.txt",
        },
      ],
    },
    nemotron_it_80: {
      code: "nemotron_it_80",
      displayName: "Nemotron 3.5 · 80 ms ⚡ ULTRA",
      fileName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-80ms-int8-2026-06-11",
      downloadUrl:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-80ms-int8-2026-06-11.tar.bz2",
      size: 682 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it",
      experimental: true,
    },
    nemotron_it_160: {
      code: "nemotron_it_160",
      displayName: "Nemotron 3.5 · 160 ms ⚡ FAST",
      fileName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-160ms-int8-2026-06-11",
      downloadUrl:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-160ms-int8-2026-06-11.tar.bz2",
      size: 682 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it",
      experimental: true,
    },
    nemotron_it_320: {
      code: "nemotron_it_320",
      displayName: "Nemotron 3.5 · 320 ms · BALANCED",
      fileName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-320ms-int8-2026-06-11",
      downloadUrl:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-320ms-int8-2026-06-11.tar.bz2",
      size: 682 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it",
      experimental: true,
    },
    nemotron_it_560: {
      code: "nemotron_it_560",
      displayName: "Nemotron 3.5 · 560 ms · ACCURACY",
      fileName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11",
      downloadUrl:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2",
      size: 682 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it",
      experimental: true,
    },
    nemotron_it_1120: {
      code: "nemotron_it_1120",
      displayName: "Nemotron 3.5 · 1120 ms · MAX CONTEXT",
      fileName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11",
      downloadUrl:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11.tar.bz2",
      size: 682 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
      languageCode: "it",
      experimental: true,
    },
    zh: {
      code: "zh",
      displayName: "中文",
      fileName: "sherpa-onnx-streaming-zipformer-zh-2025-06-30",
      size: 150 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "zh-CN",
    },
    ko: {
      code: "ko",
      displayName: "한국어",
      fileName: "sherpa-onnx-streaming-zipformer-korean-2024-06-16",
      size: 200 * 1024 * 1024,
      type: "transducer",
      requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
      languageCode: "ko-KR",
    },
  }

  private constructor() {}

  static getInstance(): STTModelManager {
    if (!STTModelManager.instance) {
      STTModelManager.instance = new STTModelManager()
    }
    return STTModelManager.instance
  }

  async getCurrentLanguageFromPreferences(): Promise<string> {
    try {
      const path = await BluetoothSdk.getSttModelPath()
      if (
        path &&
        (path.includes("/stt_models/custom") ||
          path.includes("/stt_models/quarantine/") ||
          path.includes("/stt_models/library/"))
      ) {
        this.currentLanguage = "custom"
        return "custom"
      }
      const code = path && path.length > 0 ? this.getLanguageFromPath(path) : ""
      if (code && this.languages[code]) {
        this.currentLanguage = code
        return code
      }
      return ""
    } catch (error) {
      console.error("Error getting current STT language from preferences:", error)
      return ""
    }
  }

  private friendlyModelNameFromPath(path: string): string {
    const leaf = (path.split("/").pop() || "Custom Sherpa model").replace(/\.tar\.bz2$/i, "")
    const lower = leaf.toLowerCase()
    const nemotron = lower.match(/nemotron[^/]*?(80|160|320|560|1120)ms/)
    if (nemotron) return `Nemotron 3.5 · ${nemotron[1]} ms`
    if (lower.includes("kroko")) return "Italian Built-in · Kroko INT8"
    return leaf
      .replace(/^sherpa-onnx-/i, "")
      .replace(/-int8-\d{4}-\d{2}-\d{2}$/i, "")
      .replace(/[-_]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
  }

  async getCurrentModelSummary(): Promise<CurrentModelSummary> {
    const path = await BluetoothSdk.getSttModelPath()
    if (!path) return {code: "", displayName: "No model selected", path: "", custom: false}

    if (
      path.includes("/stt_models/custom") ||
      path.includes("/stt_models/quarantine/") ||
      path.includes("/stt_models/library/")
    ) {
      try {
        const metadataPath = `${path}/${CUSTOM_METADATA}`
        if (await RNFS.exists(metadataPath)) {
          const metadata = JSON.parse(await RNFS.readFile(metadataPath, "utf8")) as {
            displayName?: string
            source?: string
          }
          return {
            code: "custom",
            displayName: metadata.displayName || "Custom Sherpa model",
            path,
            custom: true,
            source: metadata.source,
          }
        }
      } catch (error) {
        console.warn("STTModelManager: custom metadata read failed", error)
      }
      const leaf = path.split("/").pop() || "Sherpa model"
      return {
        code: "custom",
        displayName: leaf === "custom" ? "Custom Sherpa model" : this.friendlyModelNameFromPath(path),
        path,
        custom: true,
      }
    }

    const code = this.getLanguageFromPath(path)
    const config = this.languages[code]
    if (config) {
      return {
        code,
        displayName: code === "it" ? "Italian Built-in · Kroko INT8" : config.displayName,
        path,
        custom: false,
        source: "G2 LABS",
      }
    }
    return {code, displayName: code || "Unknown model", path, custom: false}
  }

  private async writeModelMetadata(
    modelPath: string,
    displayName: string,
    source: string,
    sourceUrl = "",
    options?: {
      id?: string
      runtime?: ModelRuntime
      languageCode?: string
      runnable?: boolean
    },
  ): Promise<void> {
    const metadata = {
      id: options?.id ?? this.safeCatalogId(displayName),
      displayName,
      source,
      sourceUrl,
      runtime: options?.runtime ?? "sherpa-onnx",
      languageCode: options?.languageCode ?? "it-IT",
      runnable: options?.runnable ?? true,
      installedAt: new Date().toISOString(),
    }
    await RNFS.writeFile(`${modelPath}/${CUSTOM_METADATA}`, JSON.stringify(metadata, null, 2), "utf8")
  }

  private async readModelMetadata(modelPath: string): Promise<{
    id?: string
    displayName?: string
    source?: string
    sourceUrl?: string
    runtime?: ModelRuntime
    languageCode?: string
    runnable?: boolean
    installedAt?: string
  } | null> {
    try {
      const metadataPath = `${modelPath}/${CUSTOM_METADATA}`
      if (!(await RNFS.exists(metadataPath))) return null
      return JSON.parse(await RNFS.readFile(metadataPath, "utf8"))
    } catch {
      return null
    }
  }

  private getLibraryDirectory(): string {
    return `${this.getModelDirectory()}/library`
  }

  private async findMetadataDirectories(root: string, depth = 0): Promise<string[]> {
    if (!(await RNFS.exists(root)) || depth > 3) return []
    const result: string[] = []
    if (await RNFS.exists(`${root}/${CUSTOM_METADATA}`)) result.push(root)
    const entries = await RNFS.readDir(root)
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      result.push(...(await this.findMetadataDirectories(entry.path, depth + 1)))
    }
    return result
  }

  private async directoryHasModelPayload(modelPath: string): Promise<boolean> {
    if (!(await RNFS.exists(modelPath))) return false
    const entries = await RNFS.readDir(modelPath)
    for (const entry of entries) {
      if (entry.name === CUSTOM_METADATA) continue
      if (entry.isFile() && Number(entry.size ?? 0) > 1024) return true
      if (entry.isDirectory()) {
        const nested = await RNFS.readDir(entry.path)
        if (nested.some((child) => child.name !== CUSTOM_METADATA && Number(child.size ?? 0) > 1024)) return true
      }
    }
    return false
  }

  async listInstalledModels(): Promise<InstalledModelEntry[]> {
    const currentPath = await BluetoothSdk.getSttModelPath()
    const roots = [
      this.getLibraryDirectory(),
      `${this.getModelDirectory()}/custom`,
      `${this.getModelDirectory()}/quarantine`,
    ]

    const dirs: string[] = []
    for (const root of roots) {
      dirs.push(...(await this.findMetadataDirectories(root)))
    }
    const entries: InstalledModelEntry[] = []
    for (const modelPath of dirs) {
      const metadata = await this.readModelMetadata(modelPath)
      if (!metadata) continue
      if (!(await this.directoryHasModelPayload(modelPath))) continue
      const runnable =
        metadata.runtime === "sherpa-onnx"
          ? await BluetoothSdk.validateSttModel(modelPath)
          : metadata.runnable === true
      entries.push({
        id: metadata.id ?? this.safeCatalogId(modelPath),
        displayName: metadata.displayName ?? modelPath.split("/").pop() ?? "Downloaded model",
        path: modelPath,
        source: metadata.source ?? "Downloaded",
        sourceUrl: metadata.sourceUrl,
        runtime: metadata.runtime ?? "unknown",
        languageCode: metadata.languageCode ?? "it-IT",
        runnable,
        current: currentPath === modelPath,
        installedAt: metadata.installedAt,
      })
    }
    return entries.sort((a, b) => (b.installedAt ?? "").localeCompare(a.installedAt ?? ""))
  }

  async activateInstalledModel(modelPath: string): Promise<void> {
    const metadata = await this.readModelMetadata(modelPath)
    if (!metadata) throw new Error("Model metadata is missing")
    const runtime = metadata.runtime ?? "unknown"
    if (runtime !== "sherpa-onnx") {
      throw new Error(`${runtime} runtime adapter is not installed yet`)
    }
    if (!(await BluetoothSdk.validateSttModel(modelPath))) {
      throw new Error("Downloaded Sherpa model is no longer valid")
    }
    const activated = await BluetoothSdk.activateSttModel(modelPath, metadata.languageCode ?? "it-IT")
    if (!activated) throw new Error("Downloaded model failed its native recognizer smoke test")
    this.currentLanguage = "custom"
  }

  async deleteInstalledModel(modelPath: string): Promise<void> {
    const modelRoot = this.getModelDirectory()
    const allowed =
      modelPath.startsWith(`${this.getLibraryDirectory()}/`) ||
      modelPath.startsWith(`${modelRoot}/custom`) ||
      modelPath.startsWith(`${modelRoot}/quarantine/`)
    if (!allowed) {
      throw new Error("Only custom/downloaded models can be deleted here")
    }

    const currentPath = await BluetoothSdk.getSttModelPath()
    if (currentPath === modelPath) {
      if (!(await this.isModelAvailable("it"))) await this.downloadModel("it")
      await this.activateLanguage("it")
    }

    if (await RNFS.exists(modelPath)) await RNFS.unlink(modelPath)
  }

  getCurrentLanguage(): string {
    return this.currentLanguage
  }

  setCurrentLanguage(code: string): void {
    if (this.languages[code]) {
      this.currentLanguage = code
    }
  }

  getBcp47ForLanguage(code?: string): string {
    const id = code || this.currentLanguage
    return this.languages[id]?.languageCode ?? "en-US"
  }

  getAvailableLanguages(): LanguageConfig[] {
    // Experimental Model Lab entries are intentionally excluded from the normal
    // Speech language picker. They remain addressable by code from G2 MODEL LAB.
    return Object.values(this.languages).filter((language) => !language.experimental)
  }

  getModelDirectory(): string {
    const baseDir = Platform.OS === "ios" ? RNFS.DocumentDirectoryPath : RNFS.DocumentDirectoryPath
    return `${baseDir}/stt_models`
  }

  getModelPath(code?: string): string {
    const id = code || this.currentLanguage
    return `${this.getModelDirectory()}/${id}`
  }

  /** Last path segment is the language code (the on-disk folder name). */
  getLanguageFromPath(path: string): string {
    return path.split("/").pop() || ""
  }

  async isModelAvailable(code?: string): Promise<boolean> {
    try {
      const id = code || this.currentLanguage

      if (id === "custom") {
        const persistedPath = await BluetoothSdk.getSttModelPath()
        if (
          persistedPath &&
          (persistedPath.includes("/stt_models/custom") || persistedPath.includes("/stt_models/library/")) &&
          (await BluetoothSdk.validateSttModel(persistedPath))
        ) {
          return true
        }

        const customBase = `${this.getModelDirectory()}/custom`
        if (await BluetoothSdk.validateSttModel(customBase)) return true
        if (await RNFS.exists(customBase)) {
          const entries = await RNFS.readDir(customBase)
          const dirs = entries.filter((entry) => entry.isDirectory())
          if (dirs.length === 1 && (await BluetoothSdk.validateSttModel(dirs[0].path))) return true
        }
        return false
      }

      const language = this.languages[id]
      if (!language) return false

      const modelPath = this.getModelPath(id)
      if (language.archiveSha256) {
        const markerPath = `${modelPath}/${NEMOTRON_MARKER}`
        if (!(await RNFS.exists(markerPath))) return false
        const marker = (await RNFS.readFile(markerPath, "utf8")).trim().toLowerCase()
        if (marker !== language.archiveSha256) return false
      }
      for (const file of language.requiredFiles) {
        const filePath = `${modelPath}/${file}`
        const exists = await RNFS.exists(filePath)
        if (!exists) {
          console.log(`Missing required STT file: ${file} at ${filePath}`)
          return false
        }
      }

      return await BluetoothSdk.validateSttModel(modelPath)
    } catch (error) {
      console.error("Error checking STT model availability:", error)
      return false
    }
  }

  async getLanguageInfo(code?: string): Promise<LanguageInfo> {
    const id = code || this.currentLanguage
    const language = this.languages[id]
    if (!language) {
      throw new Error(`Language ${id} not found`)
    }

    const downloaded = await this.isModelAvailable(id)
    const path = downloaded ? this.getModelPath(id) : undefined

    return {
      code: id,
      displayName: language.displayName,
      size: language.size,
      language: language.languageCode,
      downloaded,
      path,
      type: language.type,
    }
  }

  async getAllLanguageInfo(): Promise<LanguageInfo[]> {
    const infos: LanguageInfo[] = []
    for (const language of this.getAvailableLanguages()) {
      infos.push(await this.getLanguageInfo(language.code))
    }
    return infos
  }

  async downloadModel(
    code?: string,
    onProgress?: (progress: DownloadProgress) => void,
    onExtractionProgress?: (progress: ExtractionProgress) => void,
  ): Promise<void> {
    const id = code || this.currentLanguage
    const language = this.languages[id]
    if (!language) {
      throw new Error(`Language ${id} not found`)
    }

    const modelUrl = language.downloadUrl ?? `${this.modelBaseUrl}${language.fileName}.tar.bz2`
    const tempPath = `${RNFS.TemporaryDirectoryPath}/${language.fileName}.tar.bz2`
    const modelDir = this.getModelDirectory()
    const finalPath = this.getModelPath(id)

    try {
      await RNFS.mkdir(modelDir, {NSURLIsExcludedFromBackupKey: true})

      // Some community Sherpa models are published as individual ONNX files
      // instead of a tar.bz2 archive. Keep the existing archive path untouched,
      // but allow those models to be installed directly into the language folder.
      if (language.directFiles?.length) {
        await RNFS.mkdir(finalPath, {NSURLIsExcludedFromBackupKey: true})
        let completedBytes = 0

        for (const file of language.directFiles) {
          const destination = `${finalPath}/${file.fileName}`
          const result = RNFS.downloadFile({
            fromUrl: file.url,
            toFile: destination,
            progress: (res: RNFS.DownloadProgressCallbackResultT) => {
              const bytesWritten = completedBytes + res.bytesWritten
              const contentLength = Math.max(language.size, bytesWritten)
              const percentage = Math.min(99, Math.round((bytesWritten / contentLength) * 100))
              onProgress?.({
                jobId: res.jobId,
                bytesWritten,
                contentLength,
                percentage,
              })
            },
            progressDivider: 5,
            begin: (res: RNFS.DownloadBeginCallbackResultT) => {
              console.log(`Direct STT download started: ${file.fileName}`, res)
            },
            connectionTimeout: 30000,
            readTimeout: 30000,
          })

          this.downloadJobId = result.jobId
          const downloadResult = await result.promise
          if (downloadResult.statusCode < 200 || downloadResult.statusCode >= 300) {
            throw new Error(
              `Download failed for ${file.fileName} with status code: ${downloadResult.statusCode}`,
            )
          }

          const stat = await RNFS.stat(destination)
          completedBytes += Number(stat.size)
        }

        this.downloadJobId = undefined
        onProgress?.({
          jobId: 0,
          bytesWritten: completedBytes,
          contentLength: completedBytes,
          percentage: 100,
        })
        onExtractionProgress?.({percentage: 100})

        const valid = await BluetoothSdk.validateSttModel(finalPath)
        if (!valid) {
          throw new Error(`Downloaded STT model failed validation: ${id}`)
        }

        return
      }

      const downloadOptions = {
        fromUrl: modelUrl,
        toFile: tempPath,
        progress: (res: RNFS.DownloadProgressCallbackResultT) => {
          const percentage = Math.round((res.bytesWritten / res.contentLength) * 100)
          onProgress?.({
            jobId: res.jobId,
            bytesWritten: res.bytesWritten,
            contentLength: res.contentLength,
            percentage,
          })
        },
        progressDivider: 10,
        begin: (res: RNFS.DownloadBeginCallbackResultT) => {
          console.log("Download started:", res)
        },
        connectionTimeout: 30000,
        readTimeout: 30000,
      }

      const result = RNFS.downloadFile(downloadOptions)
      this.downloadJobId = result.jobId

      const downloadResult = await result.promise

      if (downloadResult.statusCode !== 200) {
        throw new Error(`Download failed with status code: ${downloadResult.statusCode}`)
      }

      if (language.archiveSha256) {
        const actualDigest = (await RNFS.hash(tempPath, "sha256")).toLowerCase()
        if (actualDigest !== language.archiveSha256) {
          throw new Error(`Downloaded ${id} archive has an unexpected SHA-256 digest`)
        }
      }

      onExtractionProgress?.({percentage: 0})

      if (await RNFS.exists(finalPath)) await RNFS.unlink(finalPath)

      const subscription = BluetoothSdk.addListener("extraction_progress", (event) => {
        onExtractionProgress?.({percentage: event.percentage})
      })

      try {
        const extractionResult = await BluetoothSdk.extractTarBz2(tempPath, finalPath)
        if (!extractionResult) {
          throw new Error("Native extraction returned failure status")
        }
      } catch (extractError) {
        console.error("Native extraction failed:", extractError)
        throw extractError
      } finally {
        subscription.remove()
      }

      onExtractionProgress?.({percentage: 100})

      if (!(await BluetoothSdk.validateSttModel(finalPath))) {
        throw new Error(`Extracted STT model failed validation: ${id}`)
      }
      if (language.archiveSha256) {
        await RNFS.writeFile(`${finalPath}/${NEMOTRON_MARKER}`, `${language.archiveSha256}\n`, "utf8")
      }

      await RNFS.unlink(tempPath)
      this.downloadJobId = undefined
    } catch (error) {
      this.downloadJobId = undefined

      // Best-effort cleanup; never let it mask the original error.
      try {
        if (await RNFS.exists(tempPath)) await RNFS.unlink(tempPath)
      } catch (cleanupError) {
        console.warn("STTModelManager: temp cleanup failed:", cleanupError)
      }
      try {
        if (await RNFS.exists(finalPath)) await RNFS.unlink(finalPath)
      } catch (cleanupError) {
        console.warn("STTModelManager: final cleanup failed:", cleanupError)
      }
      throw error
    }
  }

  /** Import a user-supplied Sherpa archive into a persistent library slot. */
  async importCustomArchive(
    sourcePath: string,
    languageCode = "it-IT",
    displayName = "Custom Sherpa model",
  ): Promise<void> {
    const safeName = this.safeCatalogId(displayName.replace(/\.tar\.bz2$/i, ""))
    const destination = `${this.getLibraryDirectory()}/import-${safeName}-${Date.now()}`
    await RNFS.mkdir(this.getLibraryDirectory(), {NSURLIsExcludedFromBackupKey: true})
    await RNFS.mkdir(destination, {NSURLIsExcludedFromBackupKey: true})

    try {
      const extracted = await BluetoothSdk.extractTarBz2(sourcePath, destination)
      if (!extracted) throw new Error("Could not extract custom Sherpa model archive")

      const modelPath = await this.resolveValidModelPath(destination)
      if (!modelPath) {
        throw new Error(
          "Invalid Sherpa model. Expected tokens.txt plus encoder/decoder/joiner ONNX files, or supported CTC model files.",
        )
      }

      await this.writeModelMetadata(modelPath, displayName, "Imported file", "", {
        id: `import:${safeName}`,
        runtime: "sherpa-onnx",
        languageCode,
        runnable: true,
      })
      const activated = await BluetoothSdk.activateSttModel(modelPath, languageCode)
      if (!activated) throw new Error("Custom model failed its native recognizer smoke test")
      this.currentLanguage = "custom"
    } catch (error) {
      await RNFS.unlink(destination).catch(() => undefined)
      throw error
    }
  }

  async activateCustomModel(languageCode = "it-IT"): Promise<void> {
    const installed = await this.listInstalledModels()
    const candidate = installed.find((model) => model.runtime === "sherpa-onnx" && model.runnable)
    if (!candidate) throw new Error("No valid downloaded Sherpa model is installed")
    await this.activateInstalledModel(candidate.path)
    this.currentLanguage = "custom"
  }

  getModelSourceLinks(): ModelSourceLink[] {
    return [...this.modelSourceLinks]
  }

  private inferLanguageCode(name: string): string {
    const value = name.toLowerCase()
    if (/(^|[-_.])it([-_.]|$)|italian/.test(value)) return "it-IT"
    if (/(^|[-_.])fr([-_.]|$)|french/.test(value)) return "fr-FR"
    if (/(^|[-_.])de([-_.]|$)|german/.test(value)) return "de-DE"
    if (/(^|[-_.])es([-_.]|$)|spanish/.test(value)) return "es-ES"
    if (/(^|[-_.])en([-_.]|$)|english/.test(value)) return "en-US"
    if (/nemotron|multilingual|whisper|qwen|canary|parakeet/.test(value)) return "it"
    return "it-IT"
  }

  private safeCatalogId(id: string): string {
    const cleaned = id.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "")
    return cleaned.slice(0, 96) || "remote-model"
  }

  private async resolveValidModelPath(root: string, depth = 0): Promise<string | null> {
    if (await BluetoothSdk.validateSttModel(root)) return root
    if (depth >= 3 || !(await RNFS.exists(root))) return null

    const entries = await RNFS.readDir(root)
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const found = await this.resolveValidModelPath(entry.path, depth + 1)
      if (found) return found
    }
    return null
  }

  private async fetchSherpaReleaseCatalog(query: string): Promise<RemoteCatalogModel[]> {
    const response = await fetch(
      "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/asr-models",
      {headers: {Accept: "application/vnd.github+json"}},
    )
    if (!response.ok) throw new Error(`Sherpa catalog HTTP ${response.status}`)
    const release = (await response.json()) as {
      assets?: Array<{name?: string; browser_download_url?: string; size?: number}>
    }

    const needle = query.trim().toLowerCase()
    const assets = release.assets ?? []
    return assets
      .filter((asset) => {
        const name = asset.name ?? ""
        if (!name.endsWith(".tar.bz2")) return false
        if (needle && !name.toLowerCase().includes(needle)) return false
        return true
      })
      .slice(0, 80)
      .map((asset) => {
        const name = asset.name ?? "Sherpa model"
        const lower = name.toLowerCase()
        const likely =
          lower.includes("streaming") ||
          lower.includes("online") ||
          lower.includes("nemotron") ||
          lower.includes("kroko")
        return {
          id: `sherpa:${name}`,
          displayName: name.replace(/\.tar\.bz2$/, ""),
          source: "Sherpa-ONNX GitHub",
          sourceUrl: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models",
          downloadUrl: asset.browser_download_url,
          size: asset.size,
          languageCode: this.inferLanguageCode(name),
          compatibility: likely ? "native-likely" : "native-unverified",
          runtime: "sherpa-onnx",
          downloadMode: "test",
          fileName: name,
          detail: likely
            ? "Official Sherpa archive · eligible for quarantine + native validation"
            : "Official Sherpa archive · format will be validated before activation",
          tags: ["sherpa-onnx", "tar.bz2", likely ? "streaming-candidate" : "unverified"],
        } satisfies RemoteCatalogModel
      })
  }

  private hfFileUrl(repo: string, file: string): string {
    const safePath = file
      .split("/")
      .map((part) => encodeURIComponent(part))
      .join("/")
    return `https://huggingface.co/${repo}/resolve/main/${safePath}`
  }

  private async fetchHuggingFaceCatalog(query: string): Promise<RemoteCatalogModel[]> {
    const search = query.trim() || "speech recognition"
    const response = await fetch(
      `https://huggingface.co/api/models?pipeline_tag=automatic-speech-recognition&search=${encodeURIComponent(
        search,
      )}&sort=downloads&direction=-1&limit=24&full=true`,
    )
    if (!response.ok) throw new Error(`Hugging Face catalog HTTP ${response.status}`)
    const models = ((await response.json()) as Array<{
      id?: string
      tags?: string[]
      downloads?: number
      siblings?: Array<{rfilename?: string; size?: number}>
    }>).filter((model) => {
      const id = (model.id ?? "").toLowerCase()
      const tags = (model.tags ?? []).map((tag) => tag.toLowerCase())
      return !id.includes("faster-whisper") && !id.includes("ctranslate2") && !tags.includes("ctranslate2")
    })

    const inspect = async (model: (typeof models)[number]): Promise<RemoteCatalogModel> => {
      const id = model.id ?? "unknown-model"
      let siblings = model.siblings ?? []
      if (siblings.length === 0 && id !== "unknown-model") {
        try {
          const detailResponse = await fetch(`https://huggingface.co/api/models/${id}`)
          if (detailResponse.ok) {
            const detail = (await detailResponse.json()) as {siblings?: Array<{rfilename?: string; size?: number}>}
            siblings = detail.siblings ?? []
          }
        } catch {
          // Search remains useful even if repository file inspection is rate limited.
        }
      }

      const files = siblings
        .map((item) => ({name: item.rfilename ?? "", size: item.size}))
        .filter((item) => item.name.length > 0)
      const names = files.map((item) => item.name)
      const tar = files.find((item) => item.name.endsWith(".tar.bz2"))
      const tokens = names.find((name) => /(^|\/)tokens\.txt$/i.test(name))
      const encoder =
        names.find((name) => /(^|\/)encoder\.int8\.onnx$/i.test(name)) ??
        names.find((name) => /(^|\/)encoder\.onnx$/i.test(name))
      const decoder =
        names.find((name) => /(^|\/)decoder\.int8\.onnx$/i.test(name)) ??
        names.find((name) => /(^|\/)decoder\.onnx$/i.test(name))
      const joiner =
        names.find((name) => /(^|\/)joiner\.int8\.onnx$/i.test(name)) ??
        names.find((name) => /(^|\/)joiner\.onnx$/i.test(name))
      const ctc =
        names.find((name) => /(^|\/)model\.int8\.onnx$/i.test(name)) ??
        names.find((name) => /(^|\/)model\.onnx$/i.test(name))

      let sherpaFiles: DirectModelFile[] | undefined
      if (tokens && encoder && decoder && joiner) {
        sherpaFiles = [encoder, decoder, joiner, tokens].map((fileName) => ({
          fileName: fileName.split("/").pop() ?? fileName,
          url: this.hfFileUrl(id, fileName),
          size: files.find((entry) => entry.name === fileName)?.size,
        }))
      } else if (tokens && ctc) {
        sherpaFiles = [ctc, tokens].map((fileName) => ({
          fileName: fileName.split("/").pop() ?? fileName,
          url: this.hfFileUrl(id, fileName),
          size: files.find((entry) => entry.name === fileName)?.size,
        }))
      }

      // Search V2 can also download non-Sherpa model packages straight from
      // their Hugging Face repository into the local library. We do not claim
      // they are runnable until their runtime adapter exists.
      let storeFiles: DirectModelFile[] | undefined
      if (!sherpaFiles && !tar) {
        const standalone =
          files.find((entry) => /\.(nemo|gguf)$/i.test(entry.name)) ??
          files.find((entry) => /(^|\/)model\.bin$/i.test(entry.name))
        const bundle = standalone
          ? [standalone]
          : files
              .filter((entry) =>
                /\.(onnx|json|txt|yaml|yml|model|tiktoken|safetensors|bin|pt|pth)$/i.test(entry.name),
              )
              .filter((entry) => !/(optimizer|training_args|scheduler|rng_state)/i.test(entry.name))
              .slice(0, 32)
        if (bundle.length > 0) {
          storeFiles = bundle.map((entry) => ({
            fileName: standalone ? entry.name.split("/").pop() ?? entry.name : entry.name,
            url: this.hfFileUrl(id, entry.name),
            size: entry.size,
          }))
        }
      }

      const directTest = Boolean(tar || sherpaFiles?.length)
      const directFiles = sherpaFiles ?? storeFiles
      const tags = model.tags ?? []
      const sherpaTagged =
        id.toLowerCase().includes("sherpa") || tags.some((tag) => tag.toLowerCase().includes("sherpa"))
      const hasDownload = Boolean(tar || directFiles?.length)

      return {
        id: `hf:${id}`,
        displayName: id,
        source: "Hugging Face",
        sourceUrl: `https://huggingface.co/${id}`,
        downloadUrl: tar ? this.hfFileUrl(id, tar.name) : undefined,
        directFiles,
        fileName: tar?.name,
        size: tar?.size ?? directFiles?.reduce((sum, file) => sum + (file.size ?? 0), 0) ?? undefined,
        languageCode: this.inferLanguageCode(id),
        compatibility: directTest ? (sherpaTagged ? "native-likely" : "native-unverified") : "adapter-required",
        runtime: directTest ? "sherpa-onnx" : "unknown",
        downloadMode: directTest ? "test" : "store",
        detail: directTest
          ? tar
            ? "Direct .tar.bz2 package detected · quarantine test available"
            : "Complete Sherpa ONNX file set detected · direct download + quarantine test"
          : hasDownload
            ? `Direct repository files available · download to G2 LABS library · runtime adapter required · ${model.downloads ?? 0} downloads`
            : `Discovery result · adapter/layout support required · ${model.downloads ?? 0} downloads`,
        tags,
      }
    }

    return Promise.all(models.slice(0, 18).map((model) => inspect(model)))
  }

  private async fetchWhisperCppCatalog(query: string): Promise<RemoteCatalogModel[]> {
    const response = await fetch("https://huggingface.co/api/models/ggerganov/whisper.cpp")
    if (!response.ok) throw new Error(`whisper.cpp catalog HTTP ${response.status}`)
    const detail = (await response.json()) as {siblings?: Array<{rfilename?: string; size?: number}>}
    const needle = query.trim().toLowerCase()
    return (detail.siblings ?? [])
      .map((file) => ({name: file.rfilename ?? "", size: file.size}))
      .filter((file) => file.name.endsWith(".bin"))
      .filter((file) => !needle || file.name.toLowerCase().includes(needle) || needle.includes("whisper"))
      .slice(0, 18)
      .map((file) => ({
        id: `whispercpp:${file.name}`,
        displayName: file.name.replace(/^ggml-/, "").replace(/\.bin$/, ""),
        source: "whisper.cpp · Hugging Face",
        sourceUrl: "https://huggingface.co/ggerganov/whisper.cpp/tree/main",
        downloadUrl: this.hfFileUrl("ggerganov/whisper.cpp", file.name),
        fileName: file.name,
        size: file.size,
        languageCode: "it",
        compatibility: "adapter-required",
        runtime: "whisper.cpp",
        downloadMode: "store",
        detail: "Direct GGML download · stored locally now; whisper.cpp runtime adapter required to run it",
        tags: ["whisper.cpp", "ggml", "offline"],
      }))
  }

  private fetchVoskCatalog(query: string): RemoteCatalogModel[] {
    const needle = query.trim().toLowerCase()
    const explicitVosk = !needle || needle.includes("vosk")
    if (!explicitVosk) return []

    return [
      {
        id: "vosk:vosk-model-small-it-0.22",
        displayName: "Vosk Italian Small 0.22",
        source: "Vosk model zoo",
        sourceUrl: "https://alphacephei.com/vosk/models",
        downloadUrl: "https://alphacephei.com/vosk/models/vosk-model-small-it-0.22.zip",
        fileName: "vosk-model-small-it-0.22.zip",
        size: 48 * 1024 * 1024,
        languageCode: "it-IT",
        compatibility: "adapter-required",
        runtime: "vosk",
        downloadMode: "store",
        detail: "48 MB mobile Italian model · direct download · Vosk runtime adapter required",
        tags: ["vosk", "italian", "offline", "mobile"],
      },
      {
        id: "vosk:vosk-model-it-0.22",
        displayName: "Vosk Italian Full 0.22",
        source: "Vosk model zoo",
        sourceUrl: "https://alphacephei.com/vosk/models",
        downloadUrl: "https://alphacephei.com/vosk/models/vosk-model-it-0.22.zip",
        fileName: "vosk-model-it-0.22.zip",
        size: 1200 * 1024 * 1024,
        languageCode: "it-IT",
        compatibility: "adapter-required",
        runtime: "vosk",
        downloadMode: "store",
        detail: "Approx. 1.2 GB Italian model · direct download · Vosk runtime adapter required",
        tags: ["vosk", "italian", "offline"],
      },
    ]
  }

  async browseRemoteModels(query = ""): Promise<RemoteCatalogModel[]> {
    const [sherpa, huggingFace, whisperCpp] = await Promise.allSettled([
      this.fetchSherpaReleaseCatalog(query),
      this.fetchHuggingFaceCatalog(query),
      this.fetchWhisperCppCatalog(query),
    ])

    const result: RemoteCatalogModel[] = [...this.fetchVoskCatalog(query)]
    if (sherpa.status === "fulfilled") result.push(...sherpa.value)
    if (huggingFace.status === "fulfilled") result.push(...huggingFace.value)
    if (whisperCpp.status === "fulfilled") result.push(...whisperCpp.value)

    const seen = new Set<string>()
    const deduped = result.filter((model) => {
      const key = `${model.source}:${model.displayName}`.toLowerCase()
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })

    if (deduped.length === 0) {
      const reasons = [sherpa, huggingFace, whisperCpp]
        .filter((entry): entry is PromiseRejectedResult => entry.status === "rejected")
        .map((entry) => String(entry.reason))
        .join(" · ")
      if (reasons) throw new Error(reasons)
    }

    const rank = (model: RemoteCatalogModel) => {
      if (model.downloadMode === "test" && model.compatibility === "native-likely") return 0
      if (model.downloadMode === "test") return 1
      if (model.runtime === "whisper.cpp") return 3
      if (model.runtime === "vosk") return 4
      return 2
    }

    return deduped
      .sort((a, b) => rank(a) - rank(b) || a.displayName.localeCompare(b.displayName))
      .slice(0, 80)
  }

  private async downloadDirectFiles(
    files: DirectModelFile[],
    destination: string,
    onProgress?: (progress: DownloadProgress) => void,
  ): Promise<void> {
    await RNFS.mkdir(destination, {NSURLIsExcludedFromBackupKey: true})
    const expected = files.reduce((sum, file) => sum + (file.size ?? 0), 0)
    let completed = 0

    for (const file of files) {
      const target = `${destination}/${file.fileName}`
      const slash = target.lastIndexOf("/")
      if (slash > 0) {
        await RNFS.mkdir(target.slice(0, slash), {NSURLIsExcludedFromBackupKey: true})
      }
      const transfer = RNFS.downloadFile({
        fromUrl: file.url,
        toFile: target,
        progressDivider: 2,
        progress: (event: RNFS.DownloadProgressCallbackResultT) => {
          const total = Math.max(expected, completed + event.contentLength, completed + event.bytesWritten, 1)
          onProgress?.({
            jobId: event.jobId,
            bytesWritten: completed + event.bytesWritten,
            contentLength: total,
            percentage: Math.min(99, Math.round(((completed + event.bytesWritten) / total) * 100)),
          })
        },
        connectionTimeout: 30000,
        readTimeout: 30000,
      })
      this.downloadJobId = transfer.jobId
      const result = await transfer.promise
      if (result.statusCode < 200 || result.statusCode >= 300) {
        throw new Error(`Download failed for ${file.fileName} with status ${result.statusCode}`)
      }
      const stat = await RNFS.stat(target)
      completed += Number(stat.size)
    }

    this.downloadJobId = undefined
    onProgress?.({jobId: 0, bytesWritten: completed, contentLength: Math.max(completed, 1), percentage: 100})
  }

  async downloadAndTestCatalogModel(
    model: RemoteCatalogModel,
    onProgress?: (progress: DownloadProgress) => void,
  ): Promise<void> {
    if (model.downloadMode !== "test") {
      throw new Error(`${model.runtime} runtime is not installed yet. Use Download to Library instead.`)
    }
    if (!model.downloadUrl && !model.directFiles?.length) {
      throw new Error("This source does not expose a directly testable Sherpa package.")
    }

    const safeId = this.safeCatalogId(model.id)
    const libraryRoot = this.getLibraryDirectory()
    const installRoot = `${libraryRoot}/${safeId}`
    const tempPath = `${RNFS.TemporaryDirectoryPath}/g2labs-${safeId}.tar.bz2`

    await RNFS.mkdir(libraryRoot, {NSURLIsExcludedFromBackupKey: true})
    if (await RNFS.exists(installRoot)) await RNFS.unlink(installRoot)
    if (await RNFS.exists(tempPath)) await RNFS.unlink(tempPath)
    await RNFS.mkdir(installRoot, {NSURLIsExcludedFromBackupKey: true})

    try {
      if (model.directFiles?.length) {
        await this.downloadDirectFiles(model.directFiles, installRoot, onProgress)
      } else if (model.downloadUrl) {
        const download = RNFS.downloadFile({
          fromUrl: model.downloadUrl,
          toFile: tempPath,
          progressDivider: 2,
          progress: (event: RNFS.DownloadProgressCallbackResultT) => {
            const total = Math.max(event.contentLength, event.bytesWritten, 1)
            onProgress?.({
              jobId: event.jobId,
              bytesWritten: event.bytesWritten,
              contentLength: total,
              percentage: Math.min(99, Math.round((event.bytesWritten / total) * 100)),
            })
          },
          connectionTimeout: 30000,
          readTimeout: 30000,
        })
        this.downloadJobId = download.jobId
        const result = await download.promise
        if (result.statusCode < 200 || result.statusCode >= 300) {
          throw new Error(`Download failed with status ${result.statusCode}`)
        }
        this.downloadJobId = undefined

        const extracted = await BluetoothSdk.extractTarBz2(tempPath, installRoot)
        if (!extracted) throw new Error("Archive extraction failed in quarantine")
      }

      const modelPath = await this.resolveValidModelPath(installRoot)
      if (!modelPath) {
        throw new Error(
          "QUARANTINED / REJECTED: download does not match a supported online Sherpa layout (tokens + transducer or supported CTC).",
        )
      }

      await this.writeModelMetadata(modelPath, model.displayName, model.source, model.sourceUrl, {
        id: model.id,
        runtime: "sherpa-onnx",
        languageCode: model.languageCode,
        runnable: true,
      })
      const activated = await BluetoothSdk.activateSttModel(modelPath, model.languageCode)
      if (!activated) {
        throw new Error(
          "QUARANTINED: native smoke test failed. Last-known-good model remains the rollback target.",
        )
      }
      this.currentLanguage = "custom"
    } catch (error) {
      this.downloadJobId = undefined
      await RNFS.unlink(installRoot).catch(() => undefined)
      throw error
    } finally {
      await RNFS.unlink(tempPath).catch(() => undefined)
    }
  }

  async downloadCatalogModelToLibrary(
    model: RemoteCatalogModel,
    onProgress?: (progress: DownloadProgress) => void,
  ): Promise<string> {
    if (!model.downloadUrl && !model.directFiles?.length) {
      throw new Error("No direct download is exposed by this source.")
    }

    const safeId = this.safeCatalogId(model.id)
    const destination = `${this.getModelDirectory()}/library/${safeId}`
    if (await RNFS.exists(destination)) await RNFS.unlink(destination)
    await RNFS.mkdir(destination, {NSURLIsExcludedFromBackupKey: true})

    if (model.directFiles?.length) {
      await this.downloadDirectFiles(model.directFiles, destination, onProgress)
    } else if (model.downloadUrl) {
      const fileName = model.fileName || model.downloadUrl.split("/").pop() || "model.bin"
      const target = `${destination}/${fileName}`
      const transfer = RNFS.downloadFile({
        fromUrl: model.downloadUrl,
        toFile: target,
        progressDivider: 2,
        progress: (event: RNFS.DownloadProgressCallbackResultT) => {
          const total = Math.max(event.contentLength, event.bytesWritten, 1)
          onProgress?.({
            jobId: event.jobId,
            bytesWritten: event.bytesWritten,
            contentLength: total,
            percentage: Math.min(100, Math.round((event.bytesWritten / total) * 100)),
          })
        },
        connectionTimeout: 30000,
        readTimeout: 30000,
      })
      this.downloadJobId = transfer.jobId
      const result = await transfer.promise
      if (result.statusCode < 200 || result.statusCode >= 300) {
        this.downloadJobId = undefined
        throw new Error(`Download failed with status ${result.statusCode}`)
      }
      this.downloadJobId = undefined
    }

    await this.writeModelMetadata(destination, model.displayName, model.source, model.sourceUrl, {
      id: model.id,
      runtime: model.runtime,
      languageCode: model.languageCode,
      runnable: model.runtime === "sherpa-onnx",
    })
    return destination
  }

  async cancelDownload(): Promise<void> {
    if (this.downloadJobId !== undefined) {
      await RNFS.stopDownload(this.downloadJobId)
      this.downloadJobId = undefined
    }
  }

  async deleteModel(code?: string): Promise<void> {
    const id = code || this.currentLanguage
    const modelPath = this.getModelPath(id)
    if (await RNFS.exists(modelPath)) {
      await RNFS.unlink(modelPath)
    }
  }

  async activateLanguage(code: string): Promise<void> {
    const language = this.languages[code]
    if (!language) {
      throw new Error(`Language ${code} not found`)
    }

    const isAvailable = await this.isModelAvailable(code)
    if (!isAvailable) {
      throw new Error(`Language ${code} model is not downloaded`)
    }

    const modelPath = this.getModelPath(code)
    const activated = await BluetoothSdk.activateSttModel(modelPath, language.languageCode)
    if (!activated) {
      this.currentLanguage = "it"
      throw new Error(`${language.displayName} failed its native recognizer smoke test; restored Italian Built-in`)
    }
    this.currentLanguage = code
  }

  async getStorageInfo(): Promise<{free: number; total: number}> {
    const fsInfo = await RNFS.getFSInfo()
    return {
      free: fsInfo.freeSpace,
      total: fsInfo.totalSpace,
    }
  }

  formatBytes(bytes: number): string {
    return STTModelManager.formatBytes(bytes)
  }

  static formatBytes(bytes: number): string {
    if (bytes === 0) return "0 Bytes"
    const k = 1024
    const sizes = ["Bytes", "KB", "MB", "GB"]
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i]
  }
}

const instance = STTModelManager.getInstance()
export {STTModelManager}
export default instance
