# ArchiveDesk · RAR for macOS GUI

原生 SwiftUI 压缩包管理器，支持 macOS 14+，同时支持 Apple Silicon 和 Intel。

## 安装

在 [Releases](https://github.com/HachiMiku39/rar_for_macos_gui/releases) 下载最新版 `ArchiveDesk-0.3.0-universal.dmg`，打开后把 **ArchiveDesk** 拖到 **Applications**。

这是未经 Developer ID 签名和公证的原型版本。如果 macOS 阻止打开，请优先用下方源码在 Xcode 中构建；不需要关闭系统安全保护。

## 功能

- 内置 7-Zip：浏览、解压、测试 RAR、ZIP、7z、TAR、ISO 等，无需安装命令行工具。
- 支持密码、多选解压、拖放、Finder“打开方式”、任务日志和取消。
- RAR5 创建、文件名加密、分卷与恢复数据：需另行安装 RARLAB 工具。
- 简体中文 / English / 日本語，可在设置中即时切换；支持导入 JSON 语言包。

**RAR 下载：** 设置 →“下载 RAR for macOS”，或访问 [RARLAB 官网](https://www.rarlab.com/download.htm)。选择 ARM（Apple Silicon）或 x64（Intel），解包后在设置中选择 `rar` 文件。RAR 创建器没有捆绑，使用与分发须遵守 [RARLAB 许可](https://www.rarlab.com/license.htm)。

## 从源码构建

用 Xcode 15+ 打开 `ArchiveDesk.xcodeproj`，选择 **ArchiveDesk → My Mac**，运行。内置引擎、语言文件和许可会自动打包。

```sh
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk \
  -configuration Release -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build
```

核心测试：`swift test`。真实解压测试可设置 `ARCHIVEDESK_TEST_RAR` 和 `ARCHIVEDESK_TEST_7ZZ` 为工具的绝对路径；未设置时相应测试会跳过。

## 语言包 Demo

设置 →“查看本地化示例”，然后导入 `fr-demo.json`，可体验部分法语翻译，缺失文字自动回退英语。

制作完整语言包：复制 [en.json](Resources/Languages/en.json)，修改 `id/name/locale`，翻译 `strings` 的值，保留键和 `{0}` 等占位符。详见 [语言包接口说明](Resources/LocalizationDemo/README.md)。

## English

Native macOS archive manager with a bundled extraction engine. Download the DMG from Releases and drag ArchiveDesk to Applications. Switch the interface language in Settings. RAR creation requires a separately licensed [RARLAB CLI](https://www.rarlab.com/download.htm). Open `ArchiveDesk.xcodeproj` to build. JSON language packs can be imported in Settings; missing translations fall back to English.

## 日本語

展開エンジンを内蔵した macOS ネイティブのアーカイブ管理アプリです。Releases の DMG を開き、ArchiveDesk を Applications にドラッグしてください。設定で言語を変更できます。RAR の作成には、別途ライセンスを取得した [RARLAB CLI](https://www.rarlab.com/download.htm) が必要です。JSON 言語パックの読み込みにも対応しています。

## 注意点・许可

原型尚无 Finder 右键扩展、修复向导或 App Sandbox。不同格式的所有变体不保证兼容；当前不支持 ACE、LZIP。系统对话框及原始 CLI 日志可能使用系统或工具语言。请勿用本原型处理不可信的恶意归档。

7-Zip 26.03 以独立进程运行，原始许可、LGPL 文本和对应完整源码位于 [Resources/ThirdParty](Resources/ThirdParty)。本项目与 RARLAB / WinRAR 无隶属关系。

[测试记录](VALIDATION.md) · [技术说明](docs/TECHNICAL.md)
