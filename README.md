# ArchiveDesk · 1.1 Beta

macOS 原生归档管理器，支持 macOS 14+、Apple Silicon 和 Intel。使用 SwiftUI 界面和独立命令行引擎，不自行实现 RAR 编解码。

## 1.1.0-beta.6（build 22）

- **覆盖与跳过**。等待覆盖确认时，如果另一款应用保存了同名文件，ArchiveDesk 会停止替换并保留新版本。选择“不覆盖”的条目即使随后被移走，也会保持跳过。直接解压报告显示引擎实际写入的文件数。
- **编辑压缩包**。编辑未加密的单卷 ZIP、7z 或 RAR 时会核对原包身份，在同一磁盘保留备份，并以独占方式发布编辑结果。可编辑的原包必须是只有一个硬链接的普通文件。
- **取消与拖出**。快速取消并启动下一项任务时，进度和日志跟随当前任务。从压缩包 A 开始拖出文件后切换到 B，Finder 延迟取数时会取消过期请求，避免取走 B 中同名的文件。

本版在 Apple Silicon 上通过 106 项回归，另有 5 项跳过，0 项失败。用 5,000 个文件验证了两个内置后端，均按选择跳过 500 个、写入 4,500 个。本轮未在 Intel 实机或外置 exFAT 盘上复测。外部程序在列目录与解压之间替换源包，或在提取过程中移动目标父目录，仍有竞态风险。[验证记录](VALIDATION.md)

## 1.1.0-beta.5（build 21）

- 默认直接解压到所选目录，不随机创建子文件夹，不建立完整解压暂存副本，也不额外运行整包测试。
- 同名普通文件可选择“覆盖此文件”“全部覆盖”“不覆盖”或取消；全部覆盖只影响当前压缩包。覆盖前将原文件在目标盘旁置改名为备份，不复制一份大文件。
- “新建随机命名的子文件夹”和“解压暂存”只在设置中选择开启，默认均关闭；开启的解压暂存位于目标磁盘。
- 直接解压失败或取消可能留下不完整输出，原文件备份保留；符号／硬链接和文件／文件夹类型冲突继续拒绝。解码器自身的错误检测与路径检查保留，创建压缩包时可独立选择完成后测试。
- 修复外置盘空间足够但内置盘暂存空间不足导致拒绝大包解压的问题；真实 141 GB RAR 已在本地完成约 258.6 GB 输出验证，私人样本不发布。

## 1.1.0-beta.4（build 19）

- 普通 ZIP 的 Auto 文件名模式现在会在有界中央目录样本上识别旧编码，显示 `Auto → GB18030` 等结果；浏览、单项预览和解压使用相同选择。Unicode 扩展字段保留原引擎处理；ZIP64、分卷、过大索引和混合编码不承诺自动识别，仍可手动选择。
- 文本预览新增独立“正文编码”：Auto、UTF-8、UTF-16 LE/BE、GBK、GB18030、CP932、Big5、CP949、CP437、CP850、Windows-1252、CP866、Windows-1251。自动识别为启发式，不保证短文本或混合编码正确；可在失败页直接改编码重试，无需重新解压。
- ZIP 手动文件名选项增加 CP850、Windows-1252、CP866、Windows-1251。使用文件名编码转换时仍为只读，不编辑原包。
- iOS 同类问题已在独立仓库修复为 0.3.3 Beta 2（build 10），并通过单台 iPhone / iOS 27.2 模拟器验证；不是 Mac 后端移植。详见 [编码行为与验证](docs/ENCODING.md)。

## 已发布的 1.1.0-beta.3（build 18）

- 修复加密归档内文件的预览密码流程：文件名可见不代表内容已解密；双击或按空格预览时请求密码，密码错误可重试，取消不会留下可预览的明文。
- “最近打开”仅保留在当前运行的内存中，不再写入设置或主动注册系统最近文稿；退出 App（⌘Q）后自动清除，下次启动不恢复，并清理旧版保存的记录。关闭窗口不等于退出 App。
- 保留以下媒体预览和 Miku 配色功能。下载与完整说明见 [本版发布页](https://github.com/HachiMiku39/rar_for_macos_gui/releases/tag/v1.1.0-beta.3)。

**新增 Miku 配色**：窗口右上角“外观”或设置 → 配色主题 → **Miku · 葱绿与粉色**。青绿色强调、粉色点缀与轻染色玻璃面板，主窗口、预览和任务进度窗口统一适配。主题与浅色／深色／跟随系统独立，可随时恢复标准配色；选择会自动保存。尊重系统“降低透明度”设置，不修改 Dock 图标或文件内容。

将 iOS 新版的媒体预览交互带到 Mac：双击文件、选中后按空格，或右键 → **预览**。

- 视频／音频：播放、暂停、拖动时间轴、音量；视频支持原生全屏控件，音频支持前后跳转 15 秒。
- 音乐信息：标题、艺术家、专辑等系统能识别的标签，以及内嵌 JPEG／PNG 封面。
- 图片：按窗口缩略显示、处理图片方向；动图只显示第一帧。
- 文本：只读、多编码预览，最多预览前 256 KiB，支持复制；HTML／SVG／源码仅显示文字，不执行。build 19 开始支持独立旧编码选择。
- 关闭预览即停止播放器并删除其临时副本；预览失败不影响压缩包浏览。原来的 **Quick Look**、**打开选中项**（系统默认应用）和拖出文件仍保留。

macOS 使用 **AVFoundation / AVKit / ImageIO**，不是 iOS 的 FFmpeg 解码器移植：MKV、WebM、AV1 等是否可播放取决于系统与编码，不能保证与 iOS 完全一致。解压能力不受此限制；不支持的媒体会提示解压后使用其他播放器。此开发版没有新增第三方媒体二进制依赖。

范围、安全边界及验证方法见 [媒体预览说明](docs/MEDIA-PREVIEW.md) 和 [验证记录](VALIDATION.md)。

## 安装

下载 `ArchiveDesk-1.1.0-beta.6-universal.dmg`，退出旧版后打开磁盘映像，把 ArchiveDesk 拖入“应用程序”。发布页也提供应用 ZIP、源码 ZIP 和 SHA-256 校验文件。[下载 1.1.0-beta.6](https://github.com/HachiMiku39/rar_for_macos_gui/releases/tag/v1.1.0-beta.6) · [全部版本](https://github.com/HachiMiku39/rar_for_macos_gui/releases)

**1.0 正式版：** 采用圆角底板、透明留白的新 Dock 图标。CPU 主指标显示本软件占整机逻辑核心的比例（0–100%），另列活动监视器口径的进程 CPU（单核心满载为 100%，多核可超过 100%）。两项均统计 ArchiveDesk + 当前引擎，不包括其他应用。更新时先退出旧版本，再替换 Applications 中的应用。

**1.1 为测试版，尚未经过 Developer ID 签名和 Apple 公证。** 安装包仅有本地 ad-hoc 签名，不代表 Apple 已审核，也不是 Developer ID 分发签名。如果 macOS 阻止打开，可用 Xcode 从源码构建；不需要关闭系统安全保护。旧 1.0 正式版也未经过公证。

## 1.0 功能

压缩、解压、批量解压及归档测试开始时自动打开独立进度窗口，显示阶段百分比、CPU、RAM、磁盘读写速度、目标卷占用、用时及取消。任务结束保留结果；关闭窗口只隐藏，可从“工具 → 任务进度”或主窗口底部再次打开。

- **批量解压与队列**：拖入多个压缩包，或“工具 → 批量解压”。逐个解压到同名目录；失败继续后续任务，支持排序、移除、取消整队。分卷只选首卷。
- **同名处理**：逐个覆盖、全部覆盖、不覆盖或取消，也可将不覆盖应用到当前压缩包的全部冲突。覆盖保留原文件旁置备份；暂存模式另有重命名／更新策略。
- **SHA-256 / MD5 面板**：工具 → 文件校验；流式计算、复制、粘贴预期值比对，以及导入 GNU 格式校验清单。MD5 仅用于旧值兼容，不作安全认证。
- **原生 Quick Look**：选中文件 → 工具／右键 → 快速查看。文件名列支持把单个普通文件拖到 Finder。均先安全提取临时副本，上限 512 MiB，不支持文件夹拖出或嵌套归档预览。
- **旧 ZIP 文件名编码**：Auto、UTF-8、GB18030、GBK、CP932、Big5、CP437、CP949。手动选择会重新读取列表；解压使用同一编码。该模式暂时只读，不编辑原包。
- **创建 TAR、tar.gz、tar.xz**：保留普通 Unix 权限、执行位、修改时间。此类创建不带密码、分卷、ACL 或扩展属性。
- **自定义分卷**：RAR5 / ZIP / 7z，1–4096 MiB，可输入 MiB 或 GiB，最大 4 GiB。分卷保存到新文件夹；ZIP 使用 7-Zip 的 `.zip.001` 分割形式，不是传统 `.z01`。FAT32 目标请选不超过 4095 MiB。

详细行为与限制：[1.0 beta 说明](docs/BETA-1.0.md)。

## 已有功能

- “最近打开”仅在当前运行期间保留，退出 App 后自动清除，下次启动不恢复；旧版本保存的浏览记录会清理，不影响原始文件及其他设置。
- 内置 7-Zip，浏览、解压、测试 RAR / ZIP / 7z / TAR / ISO 等；支持密码、选中项解压、文件夹导航与类型图标。
- RAR5 / ZIP / 7z 创建、压缩级别、排除规则、压缩后测试；RAR5 / 7z 文件名加密、RAR 恢复记录与恢复卷。
- 向未加密单卷 RAR / ZIP / 7z 添加、删除、重命名文件；在副本上修改并保留原包备份。编辑有容量限制。
- IPA / APK 结构、元数据及保护状态检查；不解密、脱壳、运行程序或绕过 DRM。
- 阶段进度、CPU、RAM、进程磁盘读写速率、目标卷空间、任务日志和取消。未知进度显示活动条，不伪造百分比。
- English / 简体中文 / 日本語，英语源语言与回退；可导入 JSON 语言包。支持系统／浅色／深色外观，系统支持时使用 Liquid Glass。

**RAR 创建工具不捆绑。** 设置 → 下载 RAR for macOS，或访问 [RARLAB](https://www.rarlab.com/download.htm)，解包后选择 `rar` 路径；遵守其许可。ZIP、7z、TAR 创建无需 RAR。

## 从源码构建

用 Xcode 26+（推荐 Xcode 27）打开 `ArchiveDesk.xcodeproj`，选择 ArchiveDesk → My Mac 运行。工程自动编译 Universal ZIP 编码适配器并打包资源。没有 Homebrew 运行依赖。

```sh
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk \
  -configuration Release -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build
```

`scripts/package.sh` 构建 Universal 安装包。Swift Package 主要用于核心测试：

```sh
sh scripts/build-zip-helper.sh
ARCHIVEDESK_TEST_7ZZ="$PWD/Resources/Tools/7zz" \
ARCHIVEDESK_TEST_ZIP_HELPER="$PWD/Resources/Tools/ArchiveDeskZIP" swift test
```

可选 `ARCHIVEDESK_TEST_RAR`、`ARCHIVEDESK_TEST_GHIDRA` 为测试工具／样本绝对路径，`ARCHIVEDESK_TEST_LARGE=1` 启用 5 GiB ZIP64 测试。未提供相应工具或私人样本时跳过对应测试，不下载样本。

## 本地化

复制 [英文模板](Resources/LocalizationDemo/en-template.json)，修改语言信息，只翻译 `strings` 的值，保留英文键与占位符，再从设置导入。内置 [法语 Demo](Resources/LocalizationDemo/fr-demo.json) 为部分翻译，缺失文字回退英语。[语言包说明](Resources/LocalizationDemo/README.md)。

## 边界与许可

1.0 尚无安全沙箱、暂停／断点续传、Finder 右键扩展、文件夹拖出或 100 GB 全场景验证。一般解压拒绝链接、特殊文件及大小写／Unicode 路径冲突；不承诺所有格式变体可用。取消可能保留已经完成的文件；临时文件清理不是安全擦除。不要将它当作已通过安全审计的恶意文件分析环境。

7-Zip 26.03 的许可和完整对应源码在 [Resources/ThirdParty](Resources/ThirdParty)。手动 ZIP 编码通过独立适配器调用系统 libarchive；不打包系统库。项目与 RARLAB / WinRAR 无隶属关系。

[验证记录](VALIDATION.md) · [WinRAR 功能对应](docs/WINRAR-FEATURES.md) · [可靠性边界](docs/RELIABILITY.md) · [IPA/APK](docs/MOBILE-PACKAGES.md)

## English / 日本語

Native macOS archive manager with batch extraction, checksums, Quick Look, legacy ZIP encodings and TAR creation. Version 1.1.0-beta.3 (build 18) adds media previews, encrypted-entry password prompts and session-only history. Universal macOS 14+; ad-hoc signed, without Developer ID signing or notarization. RAR creation requires a separately acquired RARLAB CLI. Switch languages in Settings.

一括展開、チェックサム、Quick Look、旧 ZIP 文字コード、TAR 作成に対応した macOS ネイティブアプリです。1.1.0-beta.3（build 18）はメディアプレビュー、暗号化ファイルのパスワード入力、終了時の閲覧履歴消去に対応します。Universal 対応ですが Developer ID 署名・公証は未実施です。RAR 作成には別途 RARLAB CLI が必要です。
