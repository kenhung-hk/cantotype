# CantoType

macOS menubar 語音輸入 app，做嘅嘢同 Typeless 一樣，但係全部喺本機行、專為廣東話而設：

1. 按住快捷鍵（預設右邊 ⌥ Option）講廣東話
2. 放手 → macOS 26 內置 on-device 語音辨識（`zh_HK`）轉成文字
3. 本機 Ollama（預設 `qwen3:14b`）刪填充詞、加標點、修正錯字，可揀保留口語或者轉書面語
4. 自動貼到你當時 focus 嘅 app

冇任何聲音或文字離開你部 Mac。

## 需要

- macOS 26（Tahoe）以上：用到新嘅 `SpeechAnalyzer` / `SpeechTranscriber`
- Xcode 26
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`），用嚟由 `project.yml` 生成 `.xcodeproj`
- [Ollama](https://ollama.com) 同一個模型（`ollama pull qwen3:14b`）。唔裝都用得，揀「原文」模式就唔經 LLM

## 開始

```sh
make gen        # 生成 CantoType.xcodeproj
make open       # 用 Xcode 開，⌘R 行
# 或者
make run        # xcodebuild 編譯再啟動
```

第一次行會要兩個權限，menubar 個 mic icon 嘅選單會提你：

| 權限 | 用途 |
|---|---|
| 麥克風 | 錄音 |
| 輔助使用（Accessibility） | 監聽全局快捷鍵、模擬 ⌘V 貼上 |

授權「輔助使用」之後如果快捷鍵仍然冇反應，結束再重開 app。

如果你揀 Fn / 🌐 做快捷鍵，要去「系統設定 › 鍵盤 › 按下 🌐 鍵時」揀「不執行任何操作」。

Apple 語言包（約 30 秒）會喺第一次啟動時自動下載，menubar 選單會顯示狀態。

## 簽名

`project.yml` 入面 `DEVELOPMENT_TEAM` 係你 keychain 裏面 Apple Development 證書嘅 team。用真證書簽名嘅好處係每次 rebuild 都保留「輔助使用」授權；如果冇證書，Xcode 會用 ad-hoc（Sign to Run Locally），咁每次 rebuild 之後可能要重新授權一次。

## 用 CLI 比較模型

App 本身就係一個 CLI，方便用你自己嘅錄音測試唔同引擎、語言、整理模式：

```sh
scripts/record_sample.sh ~/Desktop/sample.wav 8        # 錄 8 秒

BIN=build/Build/Products/Debug/CantoType.app/Contents/MacOS/CantoType
$BIN --transcribe ~/Desktop/sample.wav                   # Apple zh_HK，原文
$BIN --transcribe ~/Desktop/sample.wav --mode colloquial # + qwen3 口語整理
$BIN --transcribe ~/Desktop/sample.wav --mode written    # + 轉書面語
$BIN --transcribe ~/Desktop/sample.wav --locale yue_CN   # Apple 粵語（簡體）
$BIN --transcribe ~/Desktop/sample.wav --backend http    # 用 Whisper 伺服器
$BIN --help
```

## Whisper / 廣東話 fine-tune（可選）

如果 Apple 內置辨識唔夠準，可以起一個本地 Whisper 伺服器（Apple Silicon 用 MLX），然後喺設定 → 辨識揀「HTTP 伺服器」：

```sh
uv run server/whisper_server.py                                        # whisper-large-v3-turbo
uv run server/whisper_server.py --model mlx-community/whisper-large-v3-mlx
uv run server/whisper_server.py --model ./cantonese-mlx                # 轉好格式嘅 fine-tune
```

任何 OpenAI 相容嘅 `/v1/audio/transcriptions`（whisper.cpp server、Speaches、SenseVoice wrapper）都接得。

## 結構

```
CantoType/
  main.swift                    入口：CLI 或者 menubar app
  App/
    CantoTypeApp.swift          MenuBarExtra + Settings scene
    AppState.swift              狀態機：快捷鍵 → 錄音 → 辨識 → 整理 → 貼上
    MenuView.swift              menubar 選單
    SettingsView.swift          設定視窗（一般／辨識／整理／權限）
    HUDPanel.swift              屏幕底部浮動狀態膠囊
  Core/
    Settings.swift              UserDefaults 設定、快捷鍵／模式 enum
    HotkeyMonitor.swift         CGEvent tap 全局快捷鍵
    AudioRecorder.swift         AVAudioEngine → 16 kHz Int16
    AudioClip.swift             錄音資料、WAV、格式轉換
    TextInserter.swift          剪貼簿 + ⌘V，之後還原剪貼簿
    Permissions.swift           麥克風／輔助使用權限、提示音
    HistoryStore.swift          最近輸入記錄（~/Library/Application Support/CantoType）
  Transcription/
    TranscriptionBackend.swift  protocol + 基本文字整理
    AppleSpeechBackend.swift    macOS 26 SpeechAnalyzer（on-device）
    HTTPTranscriptionBackend.swift  OpenAI 相容 HTTP 伺服器
  Polish/
    TextPolisher.swift          Ollama client + 廣東話 prompt
  CLI/
    CLIRunner.swift             --transcribe 命令列模式
server/whisper_server.py        mlx-whisper 伺服器（可選）
scripts/record_sample.sh        錄測試音檔
```

## 之後可以做

- 錄音期間即時串流入 SpeechAnalyzer（放手一刻已經有大部分結果）
- 用 Accessibility API 直接插入文字，唔經剪貼簿
- WhisperKit 做第三個 backend，唔需要 Python
- 學習你嘅用字習慣：由「最近輸入」自動累積常用詞彙
- 語音指令（「刪除上一句」、「全部大寫」）
