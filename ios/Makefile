DEVICE   ?= 7AD2F107-7120-5300-BDB9-637C364D513B   # Ken Hung’s iPhone（xcrun devicectl list devices）
BUNDLE   := com.kenhung.CantoTypeMobile
APP      := build/Build/Products/Debug-iphoneos/CantoType.app

.PHONY: gen sim device install launch devices

Config/Signing.xcconfig:
	cp -n Config/Signing.xcconfig.example Config/Signing.xcconfig

gen: Config/Signing.xcconfig      ## 生成 .xcodeproj
	xcodegen generate

sim: gen                          ## 模擬器 build（唔需要簽名）
	xcodebuild -project CantoTypeMobile.xcodeproj -scheme CantoTypeMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true

device: gen                       ## 真機 build（自動簽名，會註冊 App Group）
	xcodebuild -project CantoTypeMobile.xcodeproj -scheme CantoTypeMobile -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build | grep -E "error|BUILD" || true

install: device                   ## 裝上 iPhone（iPhone 要解鎖、同一 Wi-Fi 或者插線）
	xcrun devicectl device install app --device $(DEVICE) $(APP)

launch:                           ## 開 app
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE)

devices:
	xcrun devicectl list devices
