import AppKit
import Foundation

// 兩個入口：
//   1. `CantoType --transcribe file.wav ...`  → 命令列模式，方便測試／比較模型
//   2. 無參數                                  → 正常 menubar app
let launchArguments = CommandLine.arguments
if CLIRunner.shouldRun(launchArguments) {
    CLIRunner.run(launchArguments)
} else {
    CantoTypeApp.main()
}
