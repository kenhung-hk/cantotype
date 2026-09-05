# CantoType iOS（鍵盤 + app）

iPhone 上嘅 CantoType：一個簡單英文鍵盤，加 🎤 錄廣東話＋英文、✨ Gemma 改寫。所有模型都喺你部 Mac 行，iPhone 經 **Tailscale** 連過去。

```
iPhone 鍵盤 🎤 錄音 → 16 kHz WAV ──Tailscale──▶ Mac CantoType 伺服器 /v1/dictate（Whisper + Qwen3）──▶ 文字插入
iPhone 鍵盤 ✨ 改寫 → 游標前後文字 ──Tailscale──▶ /v1/polish mode=rephrase（Gemma 3 12B）──▶ 取代原文
```

## Mac 嗰邊

1. CantoType（Mac）→ 設定 → **遠端** → 開「允許其他裝置經 Tailscale 連入」。伺服器會改聽 `0.0.0.0` 並要求 token。
2. 同一頁有 Tailscale IP／MagicDNS、token 同 **QR code**。
3. Mac 同 iPhone 都要登入同一個 Tailscale 帳戶並開住。

## iPhone 嗰邊

```sh
cd ios
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # 填 DEVELOPMENT_TEAM（裝上真機要）
xcodegen generate
open CantoTypeMobile.xcodeproj    # 揀你部 iPhone，⌘R
```

命令列亦得（iPhone 要解鎖，Wi-Fi 配對或者插線）：
```sh
make sim        # 模擬器 build，唔需要 team
make install    # 真機 build（自動簽名）+ 裝上 iPhone
make launch     # 開 app
```

裝好之後：

1. 開 CantoType app → 設定 → **掃描 Mac 嘅 QR code**（或者手動輸入網址同 token）→ 測試連線
2. iOS 設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → **CantoType 鍵盤**
3. 再入 CantoType 鍵盤 → 開 **允許完整存取**（鍵盤要用網絡連 Mac）
4. 打字時按 🌐 切去 CantoType 鍵盤：🎤 按一下錄、再按一下停，文字會插入；✨ 將游標前後嘅文字交 Gemma 改寫

## 鍵盤 🎤 嘅流程

1. 鍵盤先試自己錄（iOS 對鍵盤 extension 嘅麥克風好嚴，可能唔畀）。
2. 錄唔到就自動跳去 CantoType app，app 一開即刻錄；講完靜 1.3 秒自動停（一直冇聲 8 秒亦停）。
3. App 傳去 Mac 辨識＋整理，將結果放入 App Group，然後自動彈返原本個 app（用 UIApplication suspend，個人 app 用冇問題）。
4. 鍵盤再出現時即刻將文字插入。設定可以改成「按 🎤 一定跳去 app」或者關掉自動停。

## 最穩陣：Action Button／Shortcut

iOS 26 唔畀鍵盤 extension 開 app（鍵盤會試三個方法並驗證，跳唔到會話你知）。Apple 正式支援嘅路係 App Intent：

- iOS 設定 → **Action Button** → 捷徑 → 揀 **「CantoType 錄音」**。按一下即錄，講完自動送去 Mac、自動返去原本 app，鍵盤自動插入。
- 或者 Shortcuts app 加「CantoType 錄音」動作，放去 Back Tap、Lock Screen、Siri（「用 CantoType 錄音」）。

## 已知限制

- 鍵盤直接開 app：iOS 26 已封，只保留嘗試。
- 改寫只影響 `documentContext` 拿得到嘅文字（大約係游標附近一段），長文要分段。
- Info.plist 開咗 `NSAllowsArbitraryLoads`，因為 Tailscale 嘅 100.x 地址係 HTTP 而唔屬於 iOS 定義嘅「本地網絡」。想要 HTTPS 可以用 `tailscale serve` 反向代理 8787。
- App Groups（`group.com.kenhung.cantotype`）用嚟俾 app 同鍵盤共用設定；Xcode 自動簽名會幫你喺 developer 帳戶開。

## 結構

```
ios/
  project.yml                      xcodegen：app + keyboard extension 兩個 target
  Shared/
    RemoteConfig.swift             App Group 設定（網址、token、模式、模型、詞彙）
    CantoTypeClient.swift          /health、/v1/dictate、/v1/polish
    AudioCapture.swift             AVAudioEngine → 16 kHz WAV，自動增益
  CantoTypeMobile/
    App.swift, DictationModel.swift, ContentView.swift, QRScannerSheet.swift
  CantoTypeKeyboard/
    KeyboardViewController.swift   UIInputViewController，host SwiftUI
    KeyboardEngine.swift           打字、錄音、改寫、狀態
    KeyboardView.swift             QWERTY + 🎤 + ✨
```
