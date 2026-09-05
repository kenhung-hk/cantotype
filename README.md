# CantoType

macOS menubar 語音輸入 app，做嘅嘢同 Typeless 一樣，但係全部喺本機用 MLX 行、專為廣東話而設：

1. 按住快捷鍵（預設右邊 ⌥ Option）講廣東話
2. 放手 → 本地 MLX Whisper（廣東話＋英文 fine-tune）轉成文字
3. 本地 MLX Qwen3（14B 4-bit）刪填充詞、加標點、修正錯字，可揀保留口語或者轉書面語
4. 自動貼到你當時 focus 嘅 app

兩個模型由同一個 Python 伺服器提供，app 一開就自動起、一關就自動收，Xcode 按 Run 就係全部。冇任何聲音或文字離開你部 Mac。

## 需要

- macOS 26（Tahoe）以上：用到新嘅 `SpeechAnalyzer` / `SpeechTranscriber`
- Xcode 26
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`），用嚟由 `project.yml` 生成 `.xcodeproj`
- [uv](https://docs.astral.sh/uv/)（`brew install uv`）：app 用佢自動起本地 MLX 伺服器（`server/mlx_server.py`，打包喺 app bundle 入面）。第一次會下載 Whisper（約 1.6 GB）同 Qwen3（約 8 GB）
- 唔需要 Ollama。想用都可以喺設定 → 整理揀 Ollama 做 LLM

## 開始

```sh
make gen        # 生成 CantoType.xcodeproj
make open       # 用 Xcode 開，⌘R 行
# 或者
make run        # xcodebuild 編譯再啟動
```

`CantoType --lab` 啟動時直接開模型試驗室。

第一次行會要兩個權限，menubar 個 mic icon 嘅選單會提你：

| 權限 | 用途 |
|---|---|
| 麥克風 | 錄音 |
| 輔助使用（Accessibility） | 監聽全局快捷鍵、模擬 ⌘V 貼上 |

授權「輔助使用」之後如果快捷鍵仍然冇反應，結束再重開 app。

如果你揀 Fn / 🌐 做快捷鍵，要去「系統設定 › 鍵盤 › 按下 🌐 鍵時」揀「不執行任何操作」。

第一次啟動會下載模型：Whisper 約 1.6 GB（一兩分鐘），Qwen3 約 8 GB（十分鐘左右），menubar 選單會顯示進度。Whisper 就緒之後已經可以用；LLM 未就緒期間會直接貼原文，HUD 會話你知「LLM 載入中，未整理」。

## 簽名

Team ID 等簽名設定放喺 `Config/Signing.xcconfig`，呢個檔案唔會入 git（`make gen` 第一次會由 `Config/Signing.xcconfig.example` 複製一份）。預設係 ad-hoc 簽名，冇 Apple 開發者證書都 build 得；但 macOS 會將每次 rebuild 當成新 app，可能要重新授權「輔助使用」。有 Apple Development 證書就照 example 入面嘅註解填三行，授權就會一直保留。

`.xcodeproj` 亦唔入 git，由 `project.yml` 生成（`make gen` 或者 `xcodegen generate`）。

## 模型試驗室

Menubar → 「模型試驗室…」（⌘L）。錄一段（或者載入音檔）→ 一次過跑 Apple 同幾個 MLX Whisper 模型並排比較 → 揀一個結果丟俾幾個 LLM 比較 → 每行有「用呢個」直接設為預設。

- 填埋你實際講咗啲乜，每個模型會顯示字錯率（CER，唔計標點空格）；改參考文字會即時重算
- 「上一次輸入嘅錄音」載入你最近一次真正口述嘅音檔，用真人聲比較（TTS 測試音檔同真人聲結果可以差好遠）
- 內置候選只留三個（用真人聲比較過最好嘅）：Apple zh_HK、廣東話＋英文 fine-tune turbo、同佢嘅 int8 版。其他 Whisper（原版 large-v3、alvanlii、khleeloo 等）可以貼 repo 加入
- HuggingFace 格式嘅 Whisper 會由伺服器**自動轉成 MLX**（`server/convert_whisper.py`，改編自 mlx-examples），存喺 `~/Library/Application Support/CantoType/models/whisper/`；貼任何 Whisper repo 入去都得，伺服器會先查格式
- 舊版 Whisper（large-v3 之前，vocab 51865）冇 `yue` token，伺服器會自動改用 `zh` 解碼
- LLM 候選：Qwen3 4B／8B／14B／32B／30B-A3B（兩個版本）、Gemma 3 12B／27B、Qwen2.5 14B、Mistral Small 3.2、gpt-oss 20B、Llama 3.3 70B、兩個廣東話 fine-tune 7B；有 Ollama 的話佢嘅模型都會出現
- 伺服器按 request 換模型：Whisper 同一時間 keep 一個，LLM 最多 keep 三個喺記憶體

## 語音辨識引擎

| 引擎 | 優點 | 缺點 |
|---|---|---|
| **MLX Whisper 廣東話 fine-tune**（預設）`Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx` | 出正宗廣東話口語繁體，英文詞（E-mail、iPhone）聽得準，13 秒音檔 0.6 秒 | 要 uv、第一次下載 1.6 GB |
| MLX Whisper `mlx-community/whisper-large-v3-mlx` | 原版最準 | 半形標點、偶然出書面語 |
| Apple 內置 `zh_HK`（可選） | 零依賴、零下載 | 英文名／術語聽得差（security → securery） |

## LLM 整理

預設 MLX `mlx-community/Qwen3-14B-4bit`（thinking 關掉），一句約 1 至 3 秒，同 Whisper 用同一個伺服器。設定可以換 Qwen3 8B（快）或者任何 mlx-community 嘅 instruct 模型。

Ollama 仍然係一個選項，但唔推薦：Qwen3 用 `think: false` 時，Ollama runner 遇到「英文字母緊貼中文字」（`K Y嗰邊`）會中途死機回傳半截答案（0.31 同 0.33 都係）。揀 Ollama 時 app 會先正規化輸入、斬斷就換 seed 重試、再用備用模型頂住。

## 技術用語同講者背景

設定 → 整理 → 「講者背景同詞彙」。預設寫住講者係「香港嘅 full stack developer，日常講廣東話夾雜英文技術用語」，可以改成你自己。背景會寫入三個地方：

- **Whisper initial prompt**：一句自然嘅描述句，順帶提及你嘅詞彙（頭 12 個）同幾個技術詞錨點（GitHub、API、Kubernetes…）。實測放詞彙清單會令 Whisper 完全唔出字，所以一定係句子；伺服器亦會喺 prompt 令輸出變空白時自動唔用 prompt 再試一次。
- **Apple 語音 contextual strings**：詞彙同技術詞。
- **LLM system prompt**：講者背景 + 一條「修正聽錯嘅英文技術詞」規則（get hub → GitHub、sequel → SQL、post gres → PostgreSQL、Q 班 → Kubernetes、派森 → Python）+ 你自己嘅專有名詞。實測幾百個詞嘅清單會令 Qwen3 亂改（甚至加否定詞），一條有例子嘅規則反而最準。

CLI 可以用 `--plain` 關掉背景同規則嚟比較效果。

## 聲太細

- 錄音會自動增益到 -3 dBFS（最多 +30 dB），Whisper 同 Apple 都受惠；伺服器端亦會再 normalize 一次
- Whisper 嘅 `no_speech_threshold` 放寬到 0.75，細聲唔會俾佢當成靜音丟走
- 聽唔到內容時 HUD 會顯示錄音峰值（例如「-38 dB，聲太細」）並播提示音
- 設定 → 一般 → 麥克風：揀輸入裝置、即時音量測試、一鍵開系統聲音設定。Mac Studio 冇內置 mic，預設好可能係 webcam 嘅 mic，離得遠就細聲

## MLX 伺服器

```sh
uv run server/mlx_server.py                                   # Whisper + Qwen3，port 8787
uv run server/mlx_server.py --llm none                        # 只要 Whisper
uv run server/mlx_server.py --llm mlx-community/Qwen3-8B-4bit
curl -s localhost:8787/health
```

Endpoint：`POST /v1/audio/transcriptions`、`POST /v1/chat/completions`（OpenAI 相容）、`GET /health`。App 用 `--parent-pid` 起佢，app 消失伺服器就自己退出。任何 OpenAI 相容嘅伺服器（whisper.cpp server、mlx_lm.server、LM Studio）都可以喺設定填網址接入。

## CLI

App 本身就係 CLI，方便用你自己嘅錄音比較模型、測 LLM：

```sh
scripts/record_sample.sh ~/Desktop/sample.wav 8              # 錄 8 秒
BIN=build/Build/Products/Debug/CantoType.app/Contents/MacOS/CantoType
$BIN --transcribe ~/Desktop/sample.wav --backend http                   # MLX Whisper，原文 + 音量
$BIN --transcribe ~/Desktop/sample.wav --backend http --mode colloquial # + Qwen3 口語整理
$BIN --transcribe ~/Desktop/sample.wav --locale zh_HK                   # Apple 語音
$BIN --polish "呃 我覺得 K M同 K Y嗰邊 security可以做好啲" --mode written
$BIN --help
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
    ModelLab.swift              模型試驗室：錄音、並排比較辨識／LLM 模型、CER、設為預設
  Core/
    Settings.swift              UserDefaults 設定、快捷鍵／模式／Whisper 模型 enum
    MLXSidecar.swift            自動啟動／監察本地 MLX 伺服器（Whisper + LLM）
    AudioDevices.swift          CoreAudio 輸入裝置列表／選擇
    HotkeyMonitor.swift         CGEvent tap 全局快捷鍵
    AudioRecorder.swift         AVAudioEngine → 16 kHz Int16，可揀裝置、測音量
    AudioClip.swift             錄音資料、WAV、格式轉換、音量統計同自動增益
    TextInserter.swift          剪貼簿 + ⌘V，之後還原剪貼簿
    Permissions.swift           麥克風／輔助使用權限、提示音
    HistoryStore.swift          最近輸入記錄（~/Library/Application Support/CantoType）
  Transcription/
    TranscriptionBackend.swift  protocol + 基本文字整理
    AppleSpeechBackend.swift    macOS 26 SpeechAnalyzer（on-device）
    HTTPTranscriptionBackend.swift  OpenAI 相容 HTTP 伺服器
  Polish/
    TextPolisher.swift          MLX（OpenAI 相容）／Ollama client、輸入正規化、廣東話 prompt
    Vocabulary.swift            講者背景、Whisper prompt 句子、contextual strings
  CLI/
    CLIRunner.swift             --transcribe / --polish 命令列模式
server/mlx_server.py            MLX 伺服器：Whisper + LLM + 模型轉換（打包入 app bundle）
server/convert_whisper.py       HuggingFace Whisper → MLX 轉換（改編自 mlx-examples，MIT）
scripts/record_sample.sh        錄測試音檔
```

## 之後可以做

- 錄音期間即時串流入 SpeechAnalyzer（放手一刻已經有大部分結果）
- 用 Accessibility API 直接插入文字，唔經剪貼簿
- 學習你嘅用字習慣：由「最近輸入」自動累積常用詞彙
- 語音指令（「刪除上一句」、「全部大寫」）
