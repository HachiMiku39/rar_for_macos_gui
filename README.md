# ArchiveDesk · 1.0 beta

macOS 原生归档管理器，支持 macOS 14+、Apple Silicon 和 Intel。使用 SwiftUI 界面和独立命令行引擎，不自行实现 RAR 编解码。

## 安装

打开 `ArchiveDesk-1.0.0-beta.3-universal.dmg`，把 ArchiveDesk 拖到 Applications。发布版本见 [Releases](https://github.com/HachiMiku39/rar_for_macos_gui/releases)。

**beta.3：** 修复 Dock 图标的启动加载；CPU 主指标改为本软件占整机逻辑核心的比例（0–100%），另列活动监视器口径的进程 CPU（单核心满载为 100%，多核可超过 100%）。两项均统计 ArchiveDesk + 当前引擎，不包括其他应用。更新时先退出旧版本，再替换 Applications 中的应用。

这是 **Beta、未经过 Developer ID 签名和公证** 的构建。如果 macOS 阻止打开，可用 Xcode 从源码构建；不需要关闭系统安全保护。本地候选包与 GitHub 发布状态分别管理。

## 1.0 beta 新功能

**beta.2 修复：** 压缩、解压、批量解压及归档测试开始时自动打开独立进度窗口，显示阶段百分比、CPU、RAM、磁盘读写速度、目标卷占用、用时及取消。任务结束保留结果；关闭窗口只隐藏，可从“工具 → 任务进度”或主窗口底部再次打开。不再仅依赖可能被弹层挡住的底部面板。

- **批量解压与队列**：拖入多个压缩包，或“工具 → 批量解压”。逐个解压到同名目录；失败继续后续任务，支持排序、移除、取消整队。分卷只选首卷。
- **应用到全部**：覆盖询问可将跳过、替换、重命名应用到当前压缩包的全部冲突。替换仍保留原文件旁置备份。
- **SHA-256 / MD5 面板**：工具 → 文件校验；流式计算、复制、粘贴预期值比对，以及导入 GNU 格式校验清单。MD5 仅用于旧值兼容，不作安全认证。
- **原生 Quick Look**：选中文件 → 工具／右键 → 快速查看。文件名列支持把单个普通文件拖到 Finder。均先安全提取临时副本，上限 512 MiB，不支持文件夹拖出或嵌套归档预览。
- **旧 ZIP 文件名编码**：Auto、UTF-8、GB18030、GBK、CP932、Big5、CP437、CP949。手动选择会重新读取列表；解压使用同一编码。该模式暂时只读，不编辑原包。
- **创建 TAR、tar.gz、tar.xz**：保留普通 Unix 权限、执行位、修改时间。此类创建不带密码、分卷、ACL 或扩展属性。
- **自定义分卷**：RAR5 / ZIP / 7z，1–4096 MiB，可输入 MiB 或 GiB，最大 4 GiB。分卷保存到新文件夹；ZIP 使用 7-Zip 的 `.zip.001` 分割形式，不是传统 `.z01`。FAT32 目标请选不超过 4095 MiB。

详细行为与限制：[1.0 beta 说明](docs/BETA-1.0.md)。

## 已有功能

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

Beta 尚无安全沙箱、暂停／断点续传、Finder 右键扩展、文件夹拖出或 100 GB 全场景验证。一般解压拒绝链接、特殊文件及大小写／Unicode 路径冲突；不承诺所有格式变体可用。取消可能保留已经完成的文件；临时文件清理不是安全擦除。不要将它当作已通过安全审计的恶意文件分析环境。

7-Zip 26.03 的许可和完整对应源码在 [Resources/ThirdParty](Resources/ThirdParty)。手动 ZIP 编码通过独立适配器调用系统 libarchive；不打包系统库。项目与 RARLAB / WinRAR 无隶属关系。

[验证记录](VALIDATION.md) · [WinRAR 功能对应](docs/WINRAR-FEATURES.md) · [可靠性边界](docs/RELIABILITY.md) · [IPA/APK](docs/MOBILE-PACKAGES.md)

## English / 日本語

Native macOS archive manager with batch extraction, checksums, Quick Look, legacy ZIP encodings and TAR creation. Unsigned Universal beta; RAR creation requires a separately acquired RARLAB CLI. Switch languages in Settings.

一括展開、チェックサム、Quick Look、旧 ZIP 文字コード、TAR 作成に対応した macOS ネイティブアプリです。未署名の Universal ベータ版です。RAR 作成には別途 RARLAB CLI が必要です。
