# FinderNotes v0.1 本地试用

本手册用于 FinderNotes v0.1 的个人本机使用与安装卸载。Dan 于 2026-09-27 明确确认 v0.1、M2 和项目整体交付通过，项目状态与交付后清理结果以 [Notion 项目首页](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)为准。步骤与预期不代表已经实测；已有失败、未验证项和 FN08-I07／FN08-I08 保留原结论，见 [历史验收记录](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/ACCEPTANCE.md)。本地测试资源和历史验收证据在交付后清理，Git 历史与 Notion 记录保留；本次交付仍为个人本机使用，未公开发布。

当前软件显示名与安装文件名统一为 **FinderNotes**／**FinderNotes.app**。真实个人安装版为 `0.1.1 (12)`；历史交付记录按构建号追溯。服务显示名为“用 FinderNotes 编辑笔记”，LocalTrial bundle ID、端口与恢复目录保持不变。

## FN-12 手动更新

`0.1.1（12）` 新增手动“检查更新…”功能，已于 2026-10-10 安全覆盖 `~/Applications/FinderNotes.app` 并获 Dan 验收。LocalTrial 身份、服务端口及草稿恢复目录保持一致。生产 feed／Release 仍未发布，检查可能返回 404，应显示失败。首次升级、签名材料准备和后续更新操作见[更新手册](UPDATES.md)；验收接受不改写历史未验证边界，也不代表 V1.0 整体发布。

## 交付身份与使用范围

| 项目 | 本地试用选择与影响 |
| --- | --- |
| 版本／构建号 | `0.1.1`／`12`，当前个人安装版；历史交付对象见固定提交中的验收记录 |
| Release bundle ID | `com.findernotes.FinderNotes.LocalTrial`，个人试用使用的独立稳定身份 |
| Finder 服务 | `用 FinderNotes 编辑笔记`；服务端口 `FinderNotesLocalTrial` |
| 默认安装位置 | `~/Applications/FinderNotes.app`，已有同名对象时拒绝覆盖 |
| 草稿恢复目录 | `~/Library/Application Support/com.findernotes.FinderNotes.LocalTrial/DraftRecovery/v1/` |
| 正式笔记 | 所选媒体的 `com.findernotes.note.v1` 自定义扩展属性，值为原始 UTF-8 正文 |
| 签名与系统要求 | 本机 ad hoc、非沙盒、未公证；工程 deployment target 为 macOS 26.0，该设置不证明 26.0 已获实测支持 |

此身份不复用 FN07Validation，也不冒充 Developer ID 签名的公开发行版。build 11 沿用 build 8 的 LocalTrial 身份、服务端口和恢复目录，仅更新新版服务显示名；已有草稿无需迁移，不要同时运行同身份的多个副本。交付后的清理以当前 `~/Applications/FinderNotes.app` 为保留对象；旧应用和已确认的测试资源按明确授权清理，无法确认属于测试的恢复草稿保留。服务标签不能替代进程身份核验，调用后须核对实际进程路径和构建号。

build 8 的实际运行环境为 macOS 26.6.2（25G83）、Apple M2、Xcode 27.0（27A266a）、Swift 6.4、内置 APFS 的独立合成 PNG/MOV，详见 [2026-09-27 build 8 实测报告](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/2026-09-27.md)。其 Release 含 arm64/x86_64，只有当前 arm64 主机经过运行测试。既有 140 项测试、真实文件与 Finder/UI 结果沿用为 build 8 历史证据，本次名称更新未据此声称 build 11 重跑通过；build 11 的构建、名称和安装核验另行留证。不能把构建成功或 deployment target 写成所有 macOS 26、Intel、大媒体、所有图片／视频格式均已支持。既有本机 ad hoc 构建带 `get-task-allow`、无 hardened runtime；不是公开分发签名配置。

## 构建产物与安装入口

以下命令构建当前 `0.1.1（12）` 产物，不安装或覆盖真实应用。从保留的仓库根目录执行。需要完整 Xcode；如位于其他位置，只给当前命令设置 `FINDERNOTES_DEVELOPER_DIR`，不更改系统全局开发目录。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build12" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh
```

上述命令使用 `.build/DerivedData-build12`；构建脚本支持 `FINDERNOTES_DERIVED_DATA`，未设置时默认 `.build/DerivedData`。当前安装器默认源为 `.build/DerivedData-build12/Build/Products/Release/FinderNotes.app`，因此按上述命令显式指定路径。build 11 历史构建曾使用 `.build/DerivedData-build11`，当前源码不重建该旧版。`local-trial` 只接受 Release。构建脚本核验代码签名、身份、版本、名称、服务及 Sparkle 配置，不会安装或覆盖当前应用。Xcode 可能向 LaunchServices 注册构建产物，因此“看到服务”不证明启动的是安装件，使用时还要核对实际进程路径。

首次安装默认复制上述 Release 到用户级安装位置，不要求管理员权限。当前真实 11 → 12 已按单独授权完成；未来安装也可以显式指定源与一个不存在的目标：

```sh
python3 -B scripts/install_local_trial.py \
  --source "/absolute/path/to/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app"
```

默认遇已有目标时保留原件并停止，不要为使脚本成功而手动删除、改名或覆盖已有应用。build 12 增加显式 `--replace-existing` 升级入口，只在后续明确授权后使用，详见[更新手册](UPDATES.md)；该入口要求正常退出应用、验证新旧身份和签名、新构建号递增，并在新包安装与复验成功后直接删除旧包。失败保留现场，不清理恢复记录。不要并行运行多个 LocalTrial 副本；它们共用恢复目录和服务身份。

交付时须保存源码 SHA、当前分支和未提交状态、完整构建命令、系统和工具链、App 的 Info.plist、签名实际结果、可执行文件及交付包摘要、安装脚本结果和最终安装路径。运行应用不需要安装 Xcode；这只说明构建依赖与运行依赖不同，不承诺其他机器已可运行。

## 首次启动与 Finder 服务

**FN08-I07 保留为未解决：** 构建 9 的历史实测中，同名服务冷启动曾进入保留的旧安装路径；仅强制登记新安装件未改变该结果。构建 11 只核验了新版服务显示名，交付后移除旧应用也不等于完成了服务路由复验。使用时先明确启动 `~/Applications/FinderNotes.app`，再选择“用 FinderNotes 编辑笔记”并核对实际路径。历史失败和边界见 [图标交付证据](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/icon-build9/README.md)及 [验收记录](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/ACCEPTANCE.md)。

1. 在 Finder 中前往 `~/Applications`，确认应用名称为 **FinderNotes.app**，双击启动。首次空窗口用于核对应用身份和恢复入口；文件应经 Finder 单选后送入服务。不要同时启动同身份的其他副本。
2. 遇到系统安全阻挡，保留完整提示及产物摘要并停止该启动步骤。不要关闭 Gatekeeper、SIP，不删除 quarantine 属性，不安装系统组件，也不自动创建安全例外。此产物未公证，外部下载后的行为另需实测；参见 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)。
3. 如服务未显示，进入 **系统设置 → 键盘 → 键盘快捷键 → 服务**，查找并由用户勾选 **用 FinderNotes 编辑笔记**。服务是否显示还取决于当前选择；这是系统服务，不需要新增 Automator 或“快捷指令”工作流。[Apple：在 App 中使用服务](https://support.apple.com/zh-cn/guide/mac-help/mchlp1012/mac)。
4. 在 Finder 单选一份要编辑的本地图片／视频，分别检查 **访达 → 服务** 和文件右键的 **服务** 菜单。调用本地试用服务后，核对窗口文件名、完整路径、初始正文与启动进程的安装路径。
5. 如顶部菜单未载入文件，记录选择、菜单、时间、应用 PID／路径与画面；重新核对选择后可单独尝试右键服务。右键成功不能把顶部失败改记为修复。不要自动重启 Finder、重置服务数据库或清除历史注册项。

服务不预设全局快捷键。Dan 可在上述“服务”设置里自行设置一个不与现有组合冲突的快捷键，再用单个独立副本核对。安装不会自动改写快捷键设置。应用内已有 `⌘S` 保存、`⌘E` 导出 Markdown、`⌘W` 关闭、`⌘Q` 退出、`⌘F` 查找、`⌘G` 查找下一个、`⌘Z` 撤销及 `⇧⌘Z` 重做。

## 编辑、保存与导出

服务只接收一个本地普通图片／视频文件。多选、目录、符号链接、硬链接和 Finder 替身按当前规则拒绝。窗口固定当前文件对象；整理、移动或替换文件前先结束编辑，不承诺编辑期间自动跟随路径变化。

完成输入并停顿约 1 秒会请求自动保存；“保存”或 `⌘S` 请求同一安全保存链。正式正文只来自自有 xattr；不读取、迁移或同步 Finder 原生注释。未写过的文件与已保存的空正文不同；没有属性的空白文件打开或原样关闭不会创建笔记，首次显式保存才创建零字节属性。

应用只有在文件身份和完整 xattr 正文回读确认后才显示已保存。保存失败、正文冲突、身份变化或结果未确认会暂停自动保存；继续输入不触发无限重试。保留草稿，先复制或导出；问题排除后手动保存成功才恢复自动保存。保存期间的新输入不应被旧结果覆盖。最后检查与写入不是原子 CAS，仍有跨进程并发窗口。

“导出”或 `⌘E` 将点击时草稿存为独立 UTF-8 Markdown 快照，默认名为完整原文件名加 `.note.md`，例如 `photo.PNG.note.md`。请选择一个不存在的目标，重名时更换名称或目录。导出不是正式 xattr 保存成功的证明，不建立双向同步、自动备份或第二套笔记库；复制和导出都保留编辑会话与恢复草稿。

关闭、切换或退出遇到未保存内容或错误时，默认返回编辑；只有明确丢弃才离开。已开始的写入需要先确认结果。中文候选未完成时先完成输入，再执行保存、导出或离开；粘贴中文不构成真实输入法验收。

## 预览、权限与冲突

预览默认展开，视频不应自动播放。左侧图标切换预览，悬停与无障碍名称应为“收起预览／展开预览”。预览失败不应阻止编辑、复制、保存或导出。Quick Look 设置了 URL 不代表已渲染成功；视频声音、播放中收起停止、长文滚动和悬停浮层须由现场观察单独确认。

应用需要当前用户能够读取文件和写入该文件的扩展属性，以及写入自己的恢复目录和用户选定的新导出文件。不会默认要求控制 Finder、辅助功能或完全磁盘访问。受保护目录若出现系统提示，记录请求来源、选择和实际结果；未经 Dan 自行决定不扩大权限、不重置 TCC。合成文件 `chmod 0444` 只测试 Unix 权限拒绝，不能作为 TCC 允许／拒绝、只读卷或沙盒证据。项目验证只使用明确的测试副本，不操作 Orbit 或真实素材；使用应用时由用户选择要编辑的文件。

外部正文变化时使用 **高级选项 → 核对外部版本…**。继续编辑保留本地；载入外部前须成功导出本地；明确覆盖前须成功导出外部并再次确认。取消或导出失败应留在原稿。外部属性不存在和存在但空字节须区别显示和保留，读取错误不能当作空正文。目标被删除、移动或同名替换时禁止自动写回，草稿仍可复制、编辑和导出。

## 已落盘草稿恢复

完成输入并空闲约 250 毫秒后排队写入恢复记录；正式笔记仍只有 xattr。恢复目录只保护本应用身份的未保存草稿，是当前用户私有权限下的本机明文，包含原路径、文件身份、原始自有 xattr 基线、草稿、修订号和时间。目录权限为 0700，UUID JSON 文件为 0600，格式版本为 1。

异常结束后启动**同一身份**的应用，选择 **高级选项 → 恢复草稿… → 恢复所选草稿**。恢复先核对原目标身份及基线，自动保存保持暂停；原目标仍安全且基线一致时，经手动保存成功才回到正常保存。恢复不按相同媒体或正文匹配副本，不自动关联移动后的文件，不迁移历史验收身份的记录。

只承诺已成功落盘的完整输入，不保证最后尚未写入的击键、未提交候选或突然断电。保存成功或明确丢弃后按当前会话版本清理对应记录；导出、复制与取消不等于丢弃。损坏、未知版本或不安全的 JSON 会让本次恢复列表读取停止；保留原文件，先保存证据和可读取草稿，再由用户决定是否把该记录移出恢复目录，应用不自动删除。未发布的 `.draft-*.tmp` 不作为有效恢复记录。

## 不依赖应用读取或导出正式笔记

属性格式固定为 `com.findernotes.note.v1` 的原始 UTF-8 字节，没有 JSON 包装；版本由属性名表示。属性缺失、属性存在且为零字节、读取失败是三种不同结果。这个格式与恢复 JSON 不同。

在仓库根目录把路径替换为要只读查看笔记的文件：

```sh
media_path="/absolute/path/to/photo.png"
python3 -B scripts/read_note.py "$media_path"
python3 -B scripts/read_note.py "$media_path" \
  --export "/absolute/path/to/a-new-note.md"
```

该独立工具不启动应用；导出只接受不存在的新目标。检查退出码与返回结果，读取失败或属性缺失不能当成成功空导出；零字节的已存笔记可以导出为空快照。源文件保持不变。这只能读取已保存 xattr，不能取出尚未保存的编辑器草稿；后者用应用复制、导出或已落盘恢复记录保护。

工具在读取前拒绝源/目标同路径及别名；使用独占暂存、完整回读和独占发布，并核对最终路径身份。只有 `export.status=created` 且退出码为 0 才表示本次核验成功。`failed` 或 `publication_unconfirmed` 不是成功；保留输出列出的 temporary/evidence 路径并检查现场，不自动删除它们或外部替换文件。确认仅限检查时刻，不能防止之后的外部修改。

也可用系统工具只读查看原始十六进制，检查命令是否成功：

```sh
/usr/bin/xattr -px com.findernotes.note.v1 "$media_path"
```

不要把 `xattr -p ... > note.md` 当作安全导出方案：重定向可先创建或截断文件，随后读取仍可能失败。独立导出的验证步骤见 [FN-08 验收说明](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/validation/fn08/README.md)。

## 复制、备份与传输边界

媒体内容 SHA-256 不包含 xattr；媒体哈希相同不能证明笔记随文件保留。复制／备份后应独立读取目的文件的自有属性，比较完整字节，并确认 Finder 原生注释及其他无关属性未被本应用改变。

| 路径 | 已有证据与本轮要求 |
| --- | --- |
| 内置 APFS 上 CLI 改名／同卷移动、`cp -p` | M0 合成 PNG/MOV 有保留证据，详见 [FN-01 原始报告](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn01/2026-09-24-xattr.md)；仅限该工具与参数 |
| Finder 改名／同卷移动／复制 | M0 为 Dan 操作后最终回读，不包含每一步中间采样；不自动扩大为所有文件操作 |
| 备份及恢复 | 没有默认保留承诺；按实际工具和选项对新副本验证，不能把普通复制当成 Time Machine 验证 |
| 跨卷、外置盘、NAS、云盘／占位文件 | 未实测的组合继续列未验证；网络卷不在当前本地文件入口承诺内 |
| ZIP 等压缩、解压、转发、上传下载 | 按实际工具、选项、解压端与接收端逐项记录；没有新证据时继续未验证 |

build 8 交付期间的独立实测：同卷 `cp -p`、`ditto` 和指定 `ditto` ZIP 往返保持属性；Python 标准 ZIP 往返丢失笔记、原生注释及测试属性，媒体哈希仍相同。完整命令与比较见 [传输报告](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/transfer.md)，结果只约束所测工具、参数与接收端，本次图标更新未重跑该实验。

Markdown 是便于独立阅读的快照，导出之后的编辑不会自动同步。应用不增加媒体备份系统，也不承诺任意传输能保留笔记。

## 卸载与保留

仅在另行决定卸载当前应用时执行：先把未保存草稿复制或导出，核对需要保留的恢复记录，再正常退出 LocalTrial 应用。在 Finder 中核对完整路径、bundle ID 和构建号，只把 `~/Applications/FinderNotes.app` 移入废纸篓。不要以所有“FinderNotes”名称批量删除；本轮交付后清理保留当前应用。

卸载应用不会主动删除媒体上的自定义笔记；恢复目录和用户导出的 Markdown 也保留。重新安装相同 LocalTrial 身份会再次使用该恢复目录。工作树中的构建副本可能仍被系统注册，因此菜单残留不证明应用仍安装于原位置；先核对路径，不自动清空 LaunchServices 缓存。

**清除媒体笔记属于破坏性操作，绝非默认卸载动作。** 删除 `com.findernotes.note.v1` 会失去那份已保存正文；先独立导出并核验，且必须另行明确选择具体文件。本文不提供批量清除命令。删除恢复 JSON 同样可能丢失唯一未保存草稿，不作为卸载步骤。

## 已验收结论与保留问题

Dan 已于 2026-09-27 明确确认 v0.1、M2 和项目整体交付通过。未执行项仍为未验证，历史失败仍按原记录保留；清理本地文件不重写 Git 历史或 Notion 记录。

FN08-I07 服务路由仍未解决。FN08-I08 的历史合成恢复 JSON 缺失仍未查明：当时轮次起始基线不完整，目录修改时间早于名称更新，验收不能确定其删除原因。此次仅清理已确认属于测试的恢复文件，不能把清理解释为恢复了此前缺失记录或证明该问题解决。

发现数据丢失、误写、错误显示已保存、权限扩大或存储方案变化时，停止相关写入，保留当前编辑器草稿、恢复记录、时间和原始输出；记录最小复现。不要为补验收扩大产品范围或改写原始失败。

历史清单、报告与失败记录固定于清理前 Git 提交：

- [FN-08 验收记录及 I07／I08](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/ACCEPTANCE.md)
- [FN-08 实测报告及未验证项](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/2026-09-27.md)
- [FN-08 历史验收说明](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/validation/fn08/README.md)
- [M0 评审报告](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn03/2026-09-24-m0-review.md)

本手册保留 v0.1 历史验收边界；FN-12 仅按本轮授权推进，不启动其他任务，也不把构建成功替代功能验收。
