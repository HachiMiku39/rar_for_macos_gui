# ArchiveDesk 0.2 — 内置解压引擎的原生 macOS 压缩包管理器

> 历史设计记录，仅描述 0.2，不代表当前版本。1.0 beta 的功能和限制以 [README](../README.md)、[Beta 说明](BETA-1.0.md)、[可靠性说明](RELIABILITY.md) 和 [验证记录](../VALIDATION.md) 为准；进程启动已替换为 posix_spawn，ZIP/7z/TAR 创建、层级导航、Quick Look 和串行队列均已加入。

SwiftUI + Foundation.Process，macOS 14 及以上。布局采用侧边栏、工具栏、文件表格和任务日志，使用系统控件及 SF Symbols。与 RARLAB / WinRAR 无隶属关系，不包含其商标图标、界面素材或编解码实现。

## 运行

1. 用 Xcode 15 或更新版本打开 `ArchiveDesk.xcodeproj`，选择 **ArchiveDesk → My Mac**，运行。
2. 直接打开或拖入压缩包，即可浏览、解压与测试。已内置官方 7-Zip 26.03 macOS Universal 引擎，无需安装或配置。
3. 若需要创建 RAR5、添加恢复记录或生成恢复卷，在 **Settings…** 中选择另行获得许可的 RARLAB `rar`。这些功能仍需该专有工具；RAR 解压不需要它。
4. 设置中可检测内置引擎、切换自定义兼容 `7zz`、恢复内置引擎，或查看随附的第三方许可与完整对应源码。

命令行构建：

```sh
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk \
  -configuration Debug -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build
open .build-xcode/Build/Products/Debug/ArchiveDesk.app
```

也提供 `Package.swift` 进行核心测试。`swift run ArchiveDesk` 仅用于界面开发，需要手动将自定义 7zz 路径指向 `Resources/Tools/7zz`。完整的内置工具、源码资源与 Finder 关联由 Xcode app target 打包；日常使用请运行 `.app`。

## 已实现

| 功能 | 行为 |
| --- | --- |
| 浏览 | 所有归档统一使用内置 `7zz l -slt`，包括 RAR/RAR5。完整路径平铺、过滤、多选。 |
| 解压 | 全部或所选项目，保留路径。每次在所选目标目录创建独立 UUID 子文件夹，不覆盖已有文件。 |
| 创建 | `rar a -ma5`，支持文件和文件夹。为避免同名来源冲突，多选源必须处于同一父目录。RAR5 是当前 RAR 格式；不创建旧 RAR4。 |
| 密码 | 创建时确认密码，可加密文件名；浏览/解压/测试时在底部输入密码后重新读取。 |
| 分卷 | MB 单位，0 表示不分卷。打开第一卷 `.part1.rar` / `.part01.rar`；同组文件放在同一目录。 |
| 测试 | 调用 CLI 的 `t`，显示实际退出码及输出。 |
| 恢复数据 | 创建时可选恢复记录；菜单可向现有 RAR 添加 3% 记录，或为分卷创建 10% `.rev` 恢复卷。修改前有确认提示。应先添加记录再生成恢复卷。 |
| Finder 入口 | 拖放文件；“打开方式 → ArchiveDesk”；文件关联等级为 Alternate，不抢占默认应用。 |
| CLI 设置 | 默认使用 app 内的工具；高级用户可覆盖路径。旧版外部 7zz 设置不会覆盖新版内置默认值。 |
| 任务 | 后台执行、输出中的百分比进度（若工具提供）、否则不定进度；取消先 SIGTERM，2 秒后仍运行则 SIGKILL。 |

## 格式范围

覆盖 [WinRAR 官方 Features 页面](https://www.win-rar.com/features.html)列举的 RAR、ZIP、CAB、ARJ、LZH、TAR、GZip、UUE、ISO、BZIP2、Z、7z 格式家族。另支持引擎可识别的 ZIPX、JAR、XZ、Zstandard、DMG、UDF、WIM、CPIO、RPM、DEB、XAR 等。拖放与 Finder 入口已注册 45 类扩展名；打开对话框不限制扩展名，实际格式由引擎识别。

`.tar.gz` / `.tgz`、`.tar.bz2` / `.tbz2`、`.tar.xz` / `.txz`、`.tar.Z` / `.taz`、`.tar.zst` / `.tzst` 等会先把外层解码到固定名称的私有临时 TAR，再展示内层内容。外层解码成功包含其校验；“测试”按钮再测试内层。普通 GZ/BZ2/XZ 是单文件压缩流，只解出该文件。UUE 使用 macOS 自带 `uudecode`，支持安全单文件名的首个 UU/base64 编码块；不支持邮件中的多个附件块。

这不是“所有 WinRAR 版本、所有压缩方法、所有损坏文件都完全一致”的承诺。7-Zip 自身不支持的 ZIPX 编码等仍会报错；历史 ACE、LZIP/.tar.lz 不在本版范围。旧分卷请从主卷打开，RAR 从第一卷、ZIP 从 `.zip`、7z 从 `.001` 打开。不会自动挂载 ISO/DMG，也不会执行自解压包中的程序。CAB/ARJ/LZH/Z/ZST 等按内置引擎能力提供，尚未逐一进行样本实测。

## 参数、密码与文件保护

- 使用 `Process.executableURL` 与独立 `arguments` 数组，不拼接 shell 命令。空格、中文、美元符号等不会被 shell 解释。RAR 禁用配置文件 `-cfg-`，子进程环境不继承 `RAR` 等隐式选项；使用 `--` 结束开关解析。
- 密码通过 stdin 的匿名管道输入，不放入 argv、环境变量、临时文件或 UserDefaults。RAR 创建需要确认密码，因此提供两行；任务结束关闭管道。密码只在应用内存中存活；Swift 字符串不提供可靠的内存清零保证。
- 加密任务运行时只显示不定进度，完成后再显示经过密码替换的日志，避免跨读取块泄露密码。目录解析使用单独的原始输出，保留真实文件名。
- stdout/stderr 并发排空，避免管道阻塞。stdout 超过约 16 MB 或 stderr 超过约 2 MB 时取消；界面仅保留末尾 200000/100000 字符。取消/失败可能留下部分文件，应用不会自动删除。
- 路径预检查拒绝绝对路径、`..`、盘符、换行等；拒绝已识别的链接，空的 ISO “Symbolic Link”字段不会误判。选中项名称含 `*` / `?` / 前导 `@` 时拒绝，避免 CLI 将它作为模式或列表文件处理。
- 此原型不是不可信压缩包的安全隔离环境。技术列表是面向人的文本，不是稳定的结构化协议；换行文件名、畸形列表、未知 CLI 版本及恶意压缩包仍需额外防护。未实现解压体积限制、沙箱服务、归档快照或列表与解压之间的防替换机制。
- 默认执行 app 内的官方 7zz，也允许用户配置其他受信任 CLI。可执行性检测不等同于签名验证，不自动删除 quarantine 属性，不绕过 Gatekeeper。多层格式需要额外的临时磁盘空间；中间 TAR 随会话释放清理，异常退出可能遗留临时目录。

## 许可与分发

[RARLAB 官方下载](https://www.rarlab.com/download.htm)提供 macOS ARM / x64 CLI。RAR 是专有试用软件；按[官方 EULA](https://www.rarlab.com/license.htm)，免费试用最长 40 天，之后继续使用需要购买许可。

RAR 的原始试用发行包与“抽取单个二进制后捆绑到第三方 App”不是同一分发情形。EULA 对分拆组件、嵌入其他软件包和捆绑设有限制，相关情形需要书面许可。本项目**不包含 RARLAB rar/unrar 二进制或 RAR 注册密钥**。购买使用许可不等于取得捆绑分发许可。

本版使用并捆绑 [7-Zip](https://www.7-zip.org/) 26.03，主要采用 GNU LGPL 2.1 或更新版，指定组件另有 BSD / unRAR 条款。[官方 FAQ](https://www.7-zip.org/faq.html)说明了商业应用使用要求。`Resources/ThirdParty/` 随 app 一并分发，含版权声明、许可全文、LGPL 文本、对应完整官方源码 `7z2603-src.tar.xz`、来源链接与 SHA-256。未改动引擎，通过独立进程调用，并允许替换兼容版本。详见该目录的 NOTICE.md。

## 工程结构

- `Sources/ArchiveCore/ArchiveCore.swift`：命令构建、条目解析、异步进程与取消。
- `Sources/ArchiveCore/ArchiveSession.swift`：压缩 TAR/UUE 预处理及临时文件生命周期。
- `Sources/ArchiveDesk/Model.swift`：操作流程、CLI 配置、文件对话框、错误和状态。
- `Sources/ArchiveDesk/ContentView.swift`：主窗口、创建表单、设置。
- `Sources/ArchiveDesk/ArchiveDeskApp.swift`：应用入口与 Finder URL 接收。
- `Resources/Info.plist`：应用信息、Finder 文档类型。
- `Resources/Tools/7zz`：官方 Universal 解压引擎；`Resources/ThirdParty/`：许可及对应完整源码。
- `Tests/ArchiveCoreTests/CoreTests.swift`：路径/参数/解析单元测试及可选真实 CLI 集成测试。

Xcode app target 直接编译全部源码；Swift Package 则将 ArchiveCore 拆成可测试模块。没有外部 Swift 依赖。

## 测试

```sh
swift test
ARCHIVEDESK_TEST_RAR=/absolute/path/to/rar \
ARCHIVEDESK_TEST_7ZZ=/absolute/path/to/7zz swift test
```

不设置环境变量时，真实 CLI 测试会跳过。测试只在临时目录创建压缩包。开发环境若是 Xcode beta，可显式设置 `DEVELOPER_DIR`；受限构建环境可能还需将模块缓存放入可写目录。不要为运行应用而关闭系统安全功能。

## 原型边界与下一步

已具备 MVP 和基础高级选项；仍未实现 Finder Sync 右键扩展、Quick Look、真正的多窗口任务队列、文件夹层级导航、旧 RAR4 创建、损坏修复向导、恢复卷还原向导以及发布签名/公证。ZIP/7z 只浏览、解压、测试，不在这个原型中创建。

外部 CLI 访问任意用户选择的文件，因此当前 app target **未启用 App Sandbox**。它不是可直接上架 Mac App Store 的交付配置。正式发布应评估受限的辅助进程、权限边界、CLI 版本适配、恶意归档测试、签名与公证。
