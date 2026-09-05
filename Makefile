APP      := build/Build/Products/Debug/CantoType.app
BIN      := $(APP)/Contents/MacOS/CantoType

.PHONY: gen build run cli clean open

gen:            ## 由 project.yml 重新生成 .xcodeproj
	xcodegen generate

build: gen      ## 用 xcodebuild 編譯 Debug 版
	xcodebuild -project CantoType.xcodeproj -scheme CantoType -configuration Debug -derivedDataPath build build | grep -E "error|warning: unre|BUILD" || true

run: build      ## 編譯後啟動 app
	pkill -x CantoType || true
	open $(APP)

open:           ## 用 Xcode 開 project
	open CantoType.xcodeproj

cli:            ## 例：make cli FILE=test.wav MODE=colloquial
	$(BIN) --transcribe $(FILE) --mode $(or $(MODE),raw) --locale $(or $(LOCALE),zh_HK)

clean:
	rm -rf build
