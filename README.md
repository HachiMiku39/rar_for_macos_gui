# ArchiveDesk · RAR for macOS GUI

原生 SwiftUI 压缩包管理器，支持 macOS 14+，同时支持 Apple Silicon 和 Intel。

## 安装

在 [Releases](https://github.com/HachiMiku39/rar_for_macos_gui/releases) 下载最新版 `ArchiveDesk-0.8.0-universal.dmg`，打开后把 **ArchiveDesk** 拖到 **Applications**。

这是未经 Developer ID 签名和公证的原型版本。如果 macOS 阻止打开，请优先用下方源码在 Xcode 中构建；不需要关闭系统安全保护。

## 0.7 新增

- **编辑压缩包**：向根目录添加文件/文件夹、删除选中项及子项、重命名单个文件。支持未加密、单卷 RAR/ZIP/7z；RAR 编辑需要官方 rar。
- **保护原包**：在副本上修改、测试及核对结果；保留原包备份后再替换。失败或提交前取消不替换原包。
- **解压选项**：新建子文件夹或合并到已有目录；覆盖前询问、跳过、自动重命名、覆盖、更新较旧文件；可选择完成后打开文件夹。
- 被覆盖的文件保留旁置备份；显示写入、跳过、重命名、备份数量；覆盖询问使用异步窗口。
- 修复无密码 RAR 创建时错误使用 `-p-`（可能被视为字面密码 `-`）的问题。

暂不编辑加密包、分卷、IPA/APK，不支持文件夹重命名。编辑仍限制单文件 512 MiB、总计 2 GiB、50000 项；普通解压在 0.8 已拆分为独立资源限制。详见 [编辑与解压说明](docs/EDITING-EXTRACTION.md)。

## 0.8：可靠性改造第一阶段

- 替换会抛出 Objective-C 异常的进程启动边界；无效引擎、目录、参数和启动失败返回任务错误，支持取消与重复使用。
- 有界日志、流式目录解析、普通解压解除 2 GiB / 512 MiB 旧限制；后台分页准备目录内容。
- 内存预算（自适应／保守／性能）、内存压力与磁盘空间监测；失败安全停止。
- 文件先写隐藏临时文件，成功后发布；保留普通 Unix 权限、执行位及修改时间。取消保留已完成文件，不发布当前未完成文件。
- Ghidra 实包完整解压、5 GiB ZIP64、22 万条目索引已验证。详见 [已实现范围与后续路线](docs/RELIABILITY.md)。尚不宣称 100 GB 全场景达标、安全链接还原或完整动态任务调度。

## 0.6 新增

- IPA／APK 结构识别、浏览、全部／选中解压；不执行包内程序，不解密或脱壳。
- 按需后台检查：IPA Bundle 元数据、逐 Mach-O／架构的加密标记；APK 包名、版本、SDK、ABI、DEX 和有限加固特征提示。
- 处理 APK 大小写冲突文件名，重命名导出并生成路径映射，避免 macOS 上静默漏文件。
- 使用用户提供的新图标。新增文字继续支持中、英、日三语。

检查与导出边界见 [IPA／APK 使用说明](docs/MOBILE-PACKAGES.md)。未检测到标记不等于已脱壳或无保护。

## 0.5 新增

创建窗口按常规、安全与恢复、文件、高级与时间分组。新增 ZIP/7z 创建、六档压缩等级、固实压缩、RAR 字典/BLAKE2/快速打开信息/时间设置、排除规则、线程上限和压缩后测试。可保存不含密码的默认配置。

[WinRAR 功能取舍与对应表](docs/WINRAR-FEATURES.md)

## 功能

- 内置 7-Zip：浏览、解压、测试 RAR、ZIP、7z、TAR、ISO 等，无需安装命令行工具。
- 支持密码、多选解压、拖放、Finder“打开方式”、任务日志和取消。
- RAR5 创建、文件名加密、分卷与恢复数据：需另行安装 RARLAB 工具。
- 简体中文 / English / 日本語，可在设置中即时切换；支持导入 JSON 语言包。
- 文件类型列与彩色分类图标；双击文件夹进入、上一级/根目录导航，搜索当前目录及子目录。
- 双击图片、视频、音频、PDF、文本或办公文档，以临时副本交给默认应用打开（需确认，单文件上限 512 MB）。不支持嵌套压缩包、可执行程序和脚本；编辑不会写回原包，退出时清理临时副本。异常退出可能留下系统临时文件，不应视为安全擦除。
- 一键清除最近记录（侧栏与 macOS 最近文稿），不删除原文件。
- macOS 26/27 原生 Liquid Glass 导航和操作区；日间、夜间或跟随系统，macOS 14/15 使用材质背景降级。

**RAR 下载：** 设置 →“下载 RAR for macOS”，或访问 [RARLAB 官网](https://www.rarlab.com/download.htm)。选择 ARM（Apple Silicon）或 x64（Intel），解包后在设置中选择 `rar` 文件。RAR 创建器没有捆绑，使用与分发须遵守 [RARLAB 许可](https://www.rarlab.com/license.htm)。

## 从源码构建

用 Xcode 26+（推荐 Xcode 27）打开 `ArchiveDesk.xcodeproj`，选择 **ArchiveDesk → My Mac**，运行。内置引擎、语言文件和许可会自动打包。

```sh
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk \
  -configuration Release -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build
```

核心测试：`swift test`。真实解压测试可设置 `ARCHIVEDESK_TEST_RAR` 和 `ARCHIVEDESK_TEST_7ZZ` 为工具的绝对路径；未设置时相应测试会跳过。

## 语言包 Demo

设置 →“查看本地化示例”，然后导入 `fr-demo.json`，可体验部分法语翻译，缺失文字自动回退英语。

制作完整语言包：复制 [en-template.json](Resources/LocalizationDemo/en-template.json)，修改 `id/name/locale`，只翻译 `strings` 的值，保留英文原文键和 `{0}` 等占位符。0.5.1 使用 schema v2，明确 `sourceLanguage: "en"`；英语是源语言、缺失翻译的回退语言及全新安装默认语言。保留现有语言选择，并兼容旧中文键 v1 语言包；新版 Demo 需要 0.5.1+。详见 [语言包接口说明](Resources/LocalizationDemo/README.md)。

## English

Native macOS archive manager with a bundled extraction engine. Download the DMG from Releases and drag ArchiveDesk to Applications. Switch the interface language in Settings. RAR creation requires a separately licensed [RARLAB CLI](https://www.rarlab.com/download.htm). Open `ArchiveDesk.xcodeproj` to build. JSON language packs can be imported in Settings; missing translations fall back to English.

## 日本語

展開エンジンを内蔵した macOS ネイティブのアーカイブ管理アプリです。Releases の DMG を開き、ArchiveDesk を Applications にドラッグしてください。設定で言語を変更できます。RAR の作成には、別途ライセンスを取得した [RARLAB CLI](https://www.rarlab.com/download.htm) が必要です。JSON 言語パックの読み込みにも対応しています。

## 注意点・许可

原型尚无 Finder 右键扩展、修复向导或 App Sandbox。不同格式的所有变体不保证兼容；当前不支持 ACE、LZIP。系统对话框及原始 CLI 日志可能使用系统或工具语言。请勿用本原型处理不可信的恶意归档。

7-Zip 26.03 以独立进程运行，原始许可、LGPL 文本和对应完整源码位于 [Resources/ThirdParty](Resources/ThirdParty)。本项目与 RARLAB / WinRAR 无隶属关系。

[测试记录](VALIDATION.md) · [技术说明](docs/TECHNICAL.md)
