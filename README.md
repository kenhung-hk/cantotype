# CantoType

macOS menubar 語音輸入 app，做嘅嘢同 Typeless 一樣，但係全部喺本機行、專為廣東話而設：

1. 按住快捷鍵（預設右邊 ⌥ Option）講廣東話
2. 放手 → 本地 MLX Whisper（廣東話＋英文 fine-tune）轉成文字；macOS 26 內置 on-device 語音辨識（`zh_HK`）做後備
3. 本機 Ollama（預設 `qwen3:14b`）刪填充詞、加標點、修正錯字，可揀保留口語或者轉書面語
4. 自動貼到你當時 focus 嘅 app

冇任何聲音或文字離開你部 Mac。

## 需要

- macOS 26（Tahoe）以上：用到新嘅 `SpeechAnalyzer` / `SpeechTranscriber`
- Xcode 26
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`），用嚟由 `project.yml` 生成 `.xcodeproj`
- [uv](https://docs.astral.sh/uv/)（`brew install uv`）：app 用佢自動起本地 MLX Whisper 伺服器，第一次會下載模型（約 1.6 GB）
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

第一次啟動會下載 MLX Whisper 模型（約 1.6 GB）同 Apple 語言包（約 30 秒），menubar 選單會顯示進度。Whisper 未就緒之前會暫時用 Apple 語音頂住，唔會等。

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

## 語音辨識引擎

| 引擎 | 優點 | 缺點 |
|---|---|---|
| **MLX Whisper 廣東話 fine-tune**（預設）`Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx` | 出正宗廣東話口語繁體，英文詞（E-mail、iPhone）聽得準，13 秒音檔 0.6 秒 | 要 uv、第一次下載 1.6 GB |
| MLX Whisper `mlx-community/whisper-large-v3-mlx` | 原版最準 | 半形標點、偶然出書面語 |
| Apple 內置 `zh_HK` | 零依賴、零下載（語言包 30 秒） | 英文名／術語聽得差（security → securery） |

伺服器由 app 自動管理：設定 → 辨識 → 揀模型，app 會 `uv run` 打包喺 bundle 入面嘅 `server/whisper_server.py`，app 結束時伺服器自己退出（`--parent-pid` 監察）。任何 HuggingFace 上 MLX 格式嘅 Whisper repo 都可以填入去；唔係 localhost 嘅網址（例如另一部機嘅 whisper.cpp server）就唔會自動起伺服器。

手動起伺服器（例如畀 CLI 用）：

```sh
uv run server/whisper_server.py --model Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx --port 8787
```

## LLM 整理（Ollama）

Qwen3 用 `think: false` 先夠快（一句約 1 秒）。已知 Ollama 嘅 runner 遇到辨識結果有「英文字母緊貼中文字」（例如 `K Y嗰邊`）會中途死機，回傳 `done: false` 嘅半截答案，兩個 Ollama 版本（0.31、0.33）都一樣。App 有三層保護：

1. 送去 LLM 之前先正規化：`K M` → `KM`，英文同中文之間加空格
2. 回應斬斷就換 seed／溫度再試一次
3. 仍然斬斷就用備用模型（預設 `qwen2.5vl:7b`，設定可改或留空），最後先會直接貼原文

測試 LLM 唔使錄音：

```sh
$BIN --polish "呃 我覺得 K M同 K Y嗰邊 security可以做好啲" --mode colloquial
$BIN --polish "..." --mode written --model qwen3:14b --fallback-model qwen2.5vl:7b
```

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
    Settings.swift              UserDefaults 設定、快捷鍵／模式／Whisper 模型 enum
    WhisperSidecar.swift        自動啟動／監察本地 MLX Whisper 伺服器
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
    TextPolisher.swift          Ollama client、輸入正規化、重試／備用模型、廣東話 prompt
  CLI/
    CLIRunner.swift             --transcribe / --polish 命令列模式
server/whisper_server.py        mlx-whisper 伺服器（打包入 app bundle）
scripts/record_sample.sh        錄測試音檔
```

## 之後可以做

- 錄音期間即時串流入 SpeechAnalyzer（放手一刻已經有大部分結果）
- 用 Accessibility API 直接插入文字，唔經剪貼簿
- LLM 都轉用 MLX（`mlx_lm.server` + `mlx-community/Qwen3-14B-4bit`），完全避開 Ollama runner 嘅 bug
- 學習你嘅用字習慣：由「最近輸入」自動累積常用詞彙
- 語音指令（「刪除上一句」、「全部大寫」）
