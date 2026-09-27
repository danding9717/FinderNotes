# FinderNotes v0.1 本地试用

本手册用于 FN-08 的个人本机试用与重复安装。步骤与预期不代表已经实测；本轮实际环境、产物摘要、失败和未验证项以 [FN-08 证据目录](evidence/fn08/) 为准。Dan 接受 FN-08、M2 整体验收和项目整体完成须分别明确记录。本轮不公开发布，不提交、推送或合并。

当前软件显示名与安装文件名统一为 **FinderNotes**／**FinderNotes.app**。版本信息在“关于 FinderNotes”中显示为 `0.1.0 (11)`；构建日志和交付包仍记录版本以便追溯。服务显示名改为“用 FinderNotes 编辑笔记”，LocalTrial bundle ID、端口与恢复目录保持不变。

## 交付身份与使用范围

| 项目 | 本地试用选择与影响 |
| --- | --- |
| 版本／构建号 | `0.1.0`／`11`，本次应用名称简化；还须用本轮源码提交、未提交差异与产物 SHA-256 锁定对象 |
| Release bundle ID | `com.findernotes.FinderNotes.LocalTrial`，个人试用使用的独立稳定身份 |
| Finder 服务 | `用 FinderNotes 编辑笔记`；服务端口 `FinderNotesLocalTrial` |
| 默认安装位置 | `~/Applications/FinderNotes.app`，已有同名对象时拒绝覆盖 |
| 保留的 build 10 | `~/Applications/FinderNotes v0.1 Local Trial Build 10.app`，铺满图标版保留 |
| 保留的 build 9 | `~/Applications/FinderNotes v0.1 Local Trial Build 9.app`，旧图标版保留 |
| 保留的 build 8 | `~/Applications/FinderNotes v0.1 Local Trial.app`，不覆盖、不移动或清理 |
| 测试身份 | `com.findernotes.FinderNotes.FN08Tests`，不声明 Finder 服务 |
| 草稿恢复目录 | `~/Library/Application Support/com.findernotes.FinderNotes.LocalTrial/DraftRecovery/v1/` |
| 正式笔记 | 所选媒体的 `com.findernotes.note.v1` 自定义扩展属性，值为原始 UTF-8 正文 |
| 签名与系统要求 | 本机 ad hoc、非沙盒、未公证；工程 deployment target 为 macOS 26.0，该设置不证明 26.0 已获实测支持 |

此身份不复用 FN07Validation，也不冒充 Developer ID 签名的公开发行版。build 11 沿用 build 8 的 LocalTrial 身份、服务端口和恢复目录，仅更新新版服务显示名；已有草稿无需迁移，这些副本不能同时运行。旧 build 8／9／10 与 FN-06／FN-07／M1 验收应用、草稿、样本与证据全部保留，不自动导入、迁移或清理。旧版服务标签保留；新标签也不能替代进程身份核验，调用后须核对实际进程路径和构建号。

build 8 的实际运行环境为 macOS 26.6.2（25G83）、Apple M2、Xcode 27.0（27A266a）、Swift 6.4、内置 APFS 的独立合成 PNG/MOV，详见 [2026-09-27 build 8 实测报告](evidence/fn08/2026-09-27.md)。其 Release 含 arm64/x86_64，只有当前 arm64 主机经过运行测试。既有 140 项测试、真实文件与 Finder/UI 结果沿用为 build 8 历史证据，本次名称更新未据此声称 build 11 重跑通过；build 11 的构建、名称和安装核验另行留证。不能把构建成功或 deployment target 写成所有 macOS 26、Intel、大媒体、所有图片／视频格式均已支持。既有本机 ad hoc 构建带 `get-task-allow`、无 hardened runtime；不是公开分发签名配置。

## 构建与安装

从本轮独立工作树的仓库根目录执行。需要完整 Xcode；如位于其他位置，只给当前命令设置 `FINDERNOTES_DEVELOPER_DIR`，不更改系统全局开发目录。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build11" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh
python3 -B scripts/install_local_trial.py
```

本次命令使用 `.build/DerivedData-build11`，保留 build 8 的 `.build/DerivedData`。构建脚本支持 `FINDERNOTES_DERIVED_DATA`；未设置时仍默认旧路径，因此本次必须使用上述显式目录。build 11 Release 产物及安装器默认源为 `.build/DerivedData-build11/Build/Products/Release/FinderNotes.app`。构建脚本进行代码签名核验，具体输出必须保存。Xcode 可能向 LaunchServices 注册构建产物，因此“看到服务”不证明启动的是安装件，Finder 试用时还要核对实际进程路径。

如后续需要重新运行完整测试，使用下面的复现命令；它不是本次已执行记录。测试使用 FN08Tests，继续无服务，结果包写入 `.build/TestResults/` 的新时间戳路径：

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build11" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/test_app.sh
```

安装脚本默认复制上述 Release 到用户级安装位置，不要求管理员权限。也可以显式指定源与一个不存在的目标：

```sh
python3 -B scripts/install_local_trial.py \
  --source "/absolute/path/to/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app"
```

目标已存在时保留原件并停止。重复安装不等于覆盖升级：先退出本次试用应用，核对来源、版本和草稿，再由用户决定保留或卸载原安装件后重新安装；不要为使脚本成功而自动删除、改名或覆盖已有应用。不要并行运行多个 LocalTrial 副本；它们共用恢复目录和服务身份。

交付时须保存源码 SHA、当前分支和未提交状态、完整构建命令、系统和工具链、App 的 Info.plist、签名实际结果、可执行文件及交付包摘要、安装脚本结果和最终安装路径。运行应用不需要安装 Xcode；这只说明构建依赖与运行依赖不同，不承诺其他机器已可运行。

## 首次启动与 Finder 服务

**构建 9 的本机实测限制：** 保留 build 8 后，同名服务的两次冷启动都仍进入旧安装路径；仅强制登记新安装件未改变这一结果。先正常退出其他 LocalTrial 实例，再从 `~/Applications/FinderNotes v0.1 Local Trial Build 9.app` 明确启动构建 9，随后调用 Finder 服务，本机已验证进入构建 9。不要同时运行两版，也不要把服务名称当作版本证明。旧应用未删除、移动或覆盖；没有重置服务数据库。要恢复构建 9 的直接服务冷启动，需 Dan 决定是否授权后续处理旧安装件，再单独复验；本轮不擅自处理。见 [图标交付证据](evidence/fn08/icon-build9/README.md)。

构建 10 仅修正图标铺满效果；本次构建 11 简化名称，仍不把上述服务问题记为已解决。使用时先明确启动 `~/Applications/FinderNotes.app`，再选择“用 FinderNotes 编辑笔记”并核对实际路径；旧版本热启动记录不是当前构建的全流程证据。

1. 在 Finder 中前往 `~/Applications`，确认应用名称为 **FinderNotes.app**，双击启动。首次空窗口用于核对应用身份和恢复入口；文件应经 Finder 单选后送入服务。不要同时启动保留的 build 8／9／10。
2. 遇到系统安全阻挡，保留完整提示及产物摘要并停止该启动步骤。不要关闭 Gatekeeper、SIP，不删除 quarantine 属性，不安装系统组件，也不自动创建安全例外。此产物未公证，外部下载后的行为另需实测；参见 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)。
3. 如服务未显示，进入 **系统设置 → 键盘 → 键盘快捷键 → 服务**，查找并由用户勾选 **用 FinderNotes 编辑笔记**。服务是否显示还取决于当前选择；这是系统服务，不需要新增 Automator 或“快捷指令”工作流。[Apple：在 App 中使用服务](https://support.apple.com/zh-cn/guide/mac-help/mchlp1012/mac)。
4. 在 Finder 单选一份本轮合成图片／视频，分别检查 **访达 → 服务** 和文件右键的 **服务** 菜单。调用本地试用服务后，核对窗口文件名、完整路径、初始正文与启动进程的安装路径。
5. 如顶部菜单未载入文件，记录选择、菜单、时间、应用 PID／路径与画面；重新核对选择后可单独尝试右键服务。右键成功不能把顶部失败改记为修复。不要自动重启 Finder、重置服务数据库或清除历史注册项。

服务不预设全局快捷键。Dan 可在上述“服务”设置里自行设置一个不与现有组合冲突的快捷键，再用单个合成文件实测。安装与测试不会自动改写快捷键设置。应用内已有 `⌘S` 保存、`⌘E` 导出 Markdown、`⌘W` 关闭、`⌘Q` 退出、`⌘F` 查找、`⌘G` 查找下一个、`⌘Z` 撤销及 `⇧⌘Z` 重做。

## 编辑、保存与导出

服务只接收一个本地普通图片／视频文件。多选、目录、符号链接、硬链接和 Finder 替身按当前规则拒绝。窗口固定当前文件对象；整理、移动或替换文件前先结束编辑，不承诺编辑期间自动跟随路径变化。

完成输入并停顿约 1 秒会请求自动保存；“保存”或 `⌘S` 请求同一安全保存链。正式正文只来自自有 xattr；不读取、迁移或同步 Finder 原生注释。未写过的文件与已保存的空正文不同；没有属性的空白文件打开或原样关闭不会创建笔记，首次显式保存才创建零字节属性。

应用只有在文件身份和完整 xattr 正文回读确认后才显示已保存。保存失败、正文冲突、身份变化或结果未确认会暂停自动保存；继续输入不触发无限重试。保留草稿，先复制或导出；问题排除后手动保存成功才恢复自动保存。保存期间的新输入不应被旧结果覆盖。最后检查与写入不是原子 CAS，仍有跨进程并发窗口。

“导出”或 `⌘E` 将点击时草稿存为独立 UTF-8 Markdown 快照，默认名为完整原文件名加 `.note.md`，例如 `photo.PNG.note.md`。请选择一个不存在的目标，重名时更换名称或目录。导出不是正式 xattr 保存成功的证明，不建立双向同步、自动备份或第二套笔记库；复制和导出都保留编辑会话与恢复草稿。

关闭、切换或退出遇到未保存内容或错误时，默认返回编辑；只有明确丢弃才离开。已开始的写入需要先确认结果。中文候选未完成时先完成输入，再执行保存、导出或离开；粘贴中文不构成真实输入法验收。

## 预览、权限与冲突

预览默认展开，视频不应自动播放。左侧图标切换预览，悬停与无障碍名称应为“收起预览／展开预览”。预览失败不应阻止编辑、复制、保存或导出。Quick Look 设置了 URL 不代表已渲染成功；视频声音、播放中收起停止、长文滚动和悬停浮层须由现场观察单独确认。

应用需要当前用户能够读取文件和写入该文件的扩展属性，以及写入自己的恢复目录和用户选定的新导出文件。不会默认要求控制 Finder、辅助功能或完全磁盘访问。受保护目录若出现系统提示，记录请求来源、选择和实际结果；未经 Dan 自行决定不扩大权限、不重置 TCC。合成文件 `chmod 0444` 只测试 Unix 权限拒绝，不能作为 TCC 允许／拒绝、只读卷或沙盒证据。试用不操作 Orbit 或真实素材。

外部正文变化时使用 **高级选项 → 核对外部版本…**。继续编辑保留本地；载入外部前须成功导出本地；明确覆盖前须成功导出外部并再次确认。取消或导出失败应留在原稿。外部属性不存在和存在但空字节须区别显示和保留，读取错误不能当作空正文。目标被删除、移动或同名替换时禁止自动写回，草稿仍可复制、编辑和导出。

## 已落盘草稿恢复

完成输入并空闲约 250 毫秒后排队写入恢复记录；正式笔记仍只有 xattr。恢复目录只保护本应用身份的未保存草稿，是当前用户私有权限下的本机明文，包含原路径、文件身份、原始自有 xattr 基线、草稿、修订号和时间。目录权限为 0700，UUID JSON 文件为 0600，格式版本为 1。

异常结束后启动**同一身份**的应用，选择 **高级选项 → 恢复草稿… → 恢复所选草稿**。恢复先核对原目标身份及基线，自动保存保持暂停；原目标仍安全且基线一致时，经手动保存成功才回到正常保存。恢复不按相同媒体或正文匹配副本，不自动关联移动后的文件，不迁移历史验收身份的记录。

只承诺已成功落盘的完整输入，不保证最后尚未写入的击键、未提交候选或突然断电。保存成功或明确丢弃后按当前会话版本清理对应记录；导出、复制与取消不等于丢弃。损坏、未知版本或不安全的 JSON 会让本次恢复列表读取停止；保留原文件，先保存证据和可读取草稿，再由用户决定是否把该记录移出恢复目录，应用不自动删除。未发布的 `.draft-*.tmp` 不作为有效恢复记录。

## 不依赖应用读取或导出正式笔记

属性格式固定为 `com.findernotes.note.v1` 的原始 UTF-8 字节，没有 JSON 包装；版本由属性名表示。属性缺失、属性存在且为零字节、读取失败是三种不同结果。这个格式与恢复 JSON 不同。

在仓库根目录把路径替换为本轮合成文件：

```sh
media_path="/absolute/path/to/findernotes-fn08-NEW/work/recovery.png"
python3 -B validation/fn08/read_note.py "$media_path"
python3 -B validation/fn08/read_note.py "$media_path" \
  --export "/absolute/path/to/a-new-note.md"
```

该独立工具不启动应用；导出只接受不存在的新目标。检查退出码与返回结果，读取失败或属性缺失不能当成成功空导出；零字节的已存笔记可以导出为空快照。源文件保持不变。这只能读取已保存 xattr，不能取出尚未保存的编辑器草稿；后者用应用复制、导出或已落盘恢复记录保护。

工具在读取前拒绝源/目标同路径及别名；使用独占暂存、完整回读和独占发布，并核对最终路径身份。只有 `export.status=created` 且退出码为 0 才表示本次核验成功。`failed` 或 `publication_unconfirmed` 不是成功；保留输出列出的 temporary/evidence 路径并检查现场，不自动删除它们或外部替换文件。确认仅限检查时刻，不能防止之后的外部修改。

也可用系统工具只读查看原始十六进制，检查命令是否成功：

```sh
/usr/bin/xattr -px com.findernotes.note.v1 "$media_path"
```

不要把 `xattr -p ... > note.md` 当作安全导出方案：重定向可先创建或截断文件，随后读取仍可能失败。独立导出的验证步骤见 [FN-08 验收说明](../validation/fn08/README.md)。

## 复制、备份与传输边界

媒体内容 SHA-256 不包含 xattr；媒体哈希相同不能证明笔记随文件保留。复制／备份后应独立读取目的文件的自有属性，比较完整字节，并确认 Finder 原生注释及其他无关属性未被本应用改变。

| 路径 | 已有证据与本轮要求 |
| --- | --- |
| 内置 APFS 上 CLI 改名／同卷移动、`cp -p` | M0 合成 PNG/MOV 有保留证据，详见 [FN-01 原始报告](evidence/fn01/2026-09-24-xattr.md)；仅限该工具与参数 |
| Finder 改名／同卷移动／复制 | M0 为 Dan 操作后最终回读，不包含每一步中间采样；不自动扩大为所有文件操作 |
| 备份及恢复 | 没有默认保留承诺；按实际工具和选项对新副本验证，不能把普通复制当成 Time Machine 验证 |
| 跨卷、外置盘、NAS、云盘／占位文件 | 未实测的组合继续列未验证；网络卷不在当前本地文件入口承诺内 |
| ZIP 等压缩、解压、转发、上传下载 | 按实际工具、选项、解压端与接收端逐项记录；没有新证据时继续未验证 |

build 8 交付期间的独立实测：同卷 `cp -p`、`ditto` 和指定 `ditto` ZIP 往返保持属性；Python 标准 ZIP 往返丢失笔记、原生注释及测试属性，媒体哈希仍相同。完整命令与比较见 [传输报告](evidence/fn08/transfer.md)，结果只约束所测工具、参数与接收端，本次图标更新未重跑该实验。

Markdown 是便于独立阅读的快照，导出之后的编辑不会自动同步。应用不增加媒体备份系统，也不承诺任意传输能保留笔记。

## 卸载与保留

先把当前未保存草稿复制或导出，核对需要保留的恢复记录，再正常退出本次 LocalTrial 应用。在 Finder 中核对完整路径及构建号，只把 `~/Applications/FinderNotes.app` 移入废纸篓；保留原 build 8／9／10，不要以所有“FinderNotes”名称批量删除。这些副本共用服务及快捷键设置，若仍使用 build 8，不应将公共服务入口作为卸载 build 11 的默认清理项。

卸载应用不会主动删除媒体上的自定义笔记；恢复目录、导出的 Markdown、FN-06／FN-07／M1 验收应用与证据也保留。重新安装相同 LocalTrial 身份会再次使用该恢复目录。工作树中的构建副本可能仍被系统注册，因此菜单残留不证明应用仍安装于原位置；先核对路径，不自动清空 LaunchServices 缓存。

**清除媒体笔记属于破坏性操作，绝非默认卸载动作。** 删除 `com.findernotes.note.v1` 会失去那份已保存正文；先独立导出并核验，且必须另行明确选择具体文件。本文不提供批量清除命令。删除恢复 JSON 同样可能丢失唯一未保存草稿，不作为卸载步骤。

## Dan 验收与问题记录

完整逐项清单见 [FN-08 验收说明](../validation/fn08/README.md)。Codex 提供独立样本、步骤与证据；Dan 实际试用后决定接受或退回。未执行项保持未验证，历史缺陷保持未解决，不能因其他任务 Done、PR 合并或看板分组改变。

发现数据丢失、误写、错误显示已保存、权限扩大或存储方案变化时，停止相关写入，保留当前编辑器草稿、合成样本、恢复记录、时间和原始输出；记录最小复现与最小处理建议。不要为补验收扩大产品范围或改写原始失败。

交付报告须包含实际支持环境、源代码和可构建工程、安装件及摘要、README、[M0 报告](evidence/fn03/2026-09-24-m0-review.md)、历次原始证据、失败／未验证项、风险、问题卡和 Dan 判断。可验收时最多设 `Review`；Dan 明确接受 FN-08 后才设 `Done` 并追加实际本地交付记录。项目整体 `Done` 仍需单独确认。
