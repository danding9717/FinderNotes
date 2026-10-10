# FN-12 验证证据

验证日期：2026-10-10。正式任务和验收状态以 [FN-12 / TASK-404](https://app.notion.com/p/3f5e7607d6498117b9b8e4db3a066ae9) 为准。本文保存代码审阅所需的验证方法与证据，不替代 Dan 的验收。

## 环境与隔离

- 基线 `main 235b13f`，实现工作树 `/Users/danding/.codex/worktrees/fn-12-app-update/FinderNotes`，分支 `codex/fn-12-app-update`；交付前尚未提交。
- 本机 macOS 26.7.1（25G241）/ Apple Silicon，Xcode 27.0（27A266a）、macOS 27 SDK、Swift 6；构建产物含 arm64 / x86_64，运行验证仅在本机 arm64 完成。
- 隔离验证阶段真实 `~/Applications/FinderNotes.app` 保持 LocalTrial `0.1.0（11）`，没有覆盖；随后 Dan 单独授权的真实首次升级见下文。正式生产 feed、Release 和更新包没有发布。公开更新仓库已创建但为空，源码仓库保持私有。
- 原生流程使用 `com.findernotes.FinderNotes.FN12Review`、独立服务、独立恢复路径、独立钥匙串 account 及 `127.0.0.1:18772`；最终中文输入回归另用 `.FN12IMEReview` 和端口 18776。HTTP ATS 例外仅存在于隔离测试包。
- 网络矩阵使用每例独立的 `.FN12NetworkChecks.<case>` 身份及端口 18773 / 18774。它使用真实 Sparkle 2.10.0，但自定义无界面 driver 只记录并取消，不安装。

## 已完成的检查

### 发布工具

`/usr/bin/python3 -B -m unittest discover -s tests -p 'test_update_tools.py' -v`：28 项通过。覆盖显式覆盖授权、身份与版本、严格签名拒绝、合法框架链接和逃逸链接、并发与源变化、真实 ditto 往返、安装后复验、旧包删除失败及锁清理失败。涉及签名和运行进程的故障注入不等同于真实系统签名或退出验收。

真实 bootstrap 在 `.build/FN12BootstrapValidation-r8ex66ni/Applications` 使用旧安装件的独立副本：默认拒绝覆盖；显式替换至 `0.1.1（12）` 后严格 codesign、文件清单及直接删除旧包通过。没有启动 LocalTrial，真实安装件清单保持一致。证据：该目录的 `result.json`。

### 真 Sparkle 网络与验签矩阵

`python3 -B validation/fn12/run_network.py`：10 项通过。结果保留在 `.build/FN12ValidationBeforePin/network/results.json` 及各例 `.stdout.json`、请求日志。

| 场景 | 实际结果 |
| --- | --- |
| 新版 | 发现 build 13，由测试 driver 取消，不安装 |
| 最新版 / 本地领先 | 分别得到 Sparkle no-update reason 1 / 2，没有降级 |
| 404 / 无效 XML / 离线 | 错误回调，没有最新版回调 |
| 超时 | Sparkle 原生超时约 60 秒，错误链 `NSURLErrorDomain -1001` |
| 错误签名 / 损坏 ZIP | `SUValidationError`，EdDSA 验证在解压前失败；无安装就绪回调 |
| 取消下载 | 收到首段 4096 字节即取消，正常结束 |

每例同时断言检查期间不能再次检查、结束后恢复可检查。`preparing-extraction` 只是 Sparkle 进度回调名称；是否真正解压以实际验证错误链为准。

### 原生窗口

已在隔离 build 12 上通过实际菜单验证发现新版、中文更新说明、最新版、本地领先、HTTP 404 和无效 XML。最新版窗口显示图标、运行中版本与蓝色确认按钮；错误窗口没有误报最新版。置顶窗口层级问题在检查中发现，已补临时降级并保留用户置顶选择。

### 组件保护

`zsh validation/fn12/run_components.sh` 使用实际产品 Swift 源、官方 Sparkle 框架及替换的测试 main。最终 **100 项通过**，覆盖保存／导出／组合输入保护、退出防重入、返回编辑、草稿正文和 revision 保留、置顶临时降级与恢复、更新期间切换置顶选择、真实 AppKit modal session 下同步拒绝退出，以及清理审计的绑定、未知状态、受限文件读取和陌生对象保留。最后新增组合输入时直接延后退出、不建 sheet，marked 范围／选择／焦点／草稿 revision／加载 generation 保留，自动保存和真实独立恢复 JSON 无副作用，提交输入后原保存与退出链可继续。保存 writer 的注入确认不替代真实 xattr 测试。证据：`.build/FN12Validation/components/results.log`、`attempt-ime-guard.log`；此前 83 项、74 项结果分别保留为 `results-before-ime-guard.log`、`results-before-path-fix.log`。

程序化 marked text 不代表真实中文输入法候选；隐藏窗口组件检查不代表真实 Finder 或更新窗口操作。

### 同路径安装、取消退出与正文

第一轮置顶协调包的真实链保留在 `.build/FN12ValidationPin`：build 12 的 PID 55844 经原生下载／验签／安装后由 Sparkle 启动 build 13 的 PID 56968。合成 PNG 设为只读后通过真实编辑产生未保存草稿；“安装并重启”触发原草稿确认，选择“返回编辑”后进程和中文／emoji 全文保留。恢复测试文件写权限后保存成功；导出面板打开期间再次请求安装，应用保持运行，完成 Markdown 导出后才允许重试。独立 `xattr -px` 解码与 Markdown 文件读取均与编辑器全文一致。证据：`native-before.json`、`native-after.json` 及 `fixtures`。

第一轮重启间隙立即调用 CUA 观察曾使工具额外启动同身份副本，造成该额外副本提示恢复目录占用。该副本正常退出后，Sparkle 实际启动的进程正常；后续链先独立核对 PID／版本，再绑定 UI，未再产生重复实例。此现象不作为产品自动重启成功或失败的依据。

第二轮带审计代码的真实链保留在 `.build/FN12ValidationAudit`：12 / PID 59827 → 同路径 13 / PID 60662，严格 codesign 通过。再次验证返回编辑和中文正文保存后独立回读。限定本次精确缓存路径的只读 observer 实际看到旧 bundle inode，约 17 毫秒后路径消失，确认此轮由 Sparkle 直接清理旧 bundle。

路径比较修复包在 `.build/FN12Validation` 完成 12 / PID 62899 → 同路径 13 / PID 63133，旧 PID 结束、单个新进程、严格 codesign 通过。`cleanup-observer.json` 再次记录本次旧 inode 出现后约 18 毫秒消失。产品 receipt `D5C6942C-CA59-4343-A309-13BB01BB2B09` 观察六次 `missing`，如实记 `unknown`：新进程启动前清理已完成，产品自身未曾看到旧 inode，不借外部测试结果制造 `completed`。

### 真实中文输入与最终更新包

首次用 `typeText` 输入 `zhongwen` 只产生拉丁文本，未作为真实输入法证明。后续使用已启用的 Apple SCIM ITABC，通过逐个物理按键与数字 `1` 选词实际得到“中文”和“中文输入”。未修改系统输入源设置。

修复前，在下载完成后保持 `中文shu ru` 组合输入，安装退出弹草稿确认；返回编辑虽保留拼音文本，原候选不能继续确认。证据完整保存在 `.build/FN12IMEValidationBeforeIMEGuard`。已在 `prepareToQuit` 最前方增加组合输入保护：仅提示“请先完成中文输入，再退出。”并取消退出，不打开确认框、不取消加载或改动草稿恢复。

最终 `.build/FN12IMEValidation` 实测：`zhongwen` 尚未确认时 CmdQ 没有退出或弹确认框，随后 `1` 仍能把**同一候选**确认为“中文”；独立 xattr 回读一致。下载更新后，在 `中文shu ru` 尚未确认时点击“安装并重启应用”，原 PID 76049 保持运行，没有 sheet，拼音草稿与磁盘“中文”基线保留。**从编辑器切换到 Sparkle 窗口后，原候选上下文仍不能继续数字选词**（得到 `shuru1`），故该跨窗口行为不记通过，保留人工验收边界，不声称解决 I07／I08。

重新完成正常中文选词并保存“中文输入”后，“检查更新…”能重新打开已下载更新，手动重试安装成功：12 / PID 76049 → 同路径 13 / PID 77128，单个新进程、strict codesign 通过，独立 xattr 全文保持“中文输入”。精确 observer 看到旧 inode `11023754` 后约 42 毫秒路径消失；产品 receipt `89966756-48E9-46D8-9F5A-64F99396DBA4` 只看到六次 missing，如实记录 unknown。证据：该目录的 `native-ime-baseline.json`、`native-ime-install-guard.json`、`native-final.json`、`cleanup-observer.json`、`receipt-89966756-48E9-46D8-9F5A-64F99396DBA4.json`。测试图片权限已恢复，最后进程正常退出。

修复前流程还实际确认：用户已经点击“安装并重启”后取消退出，Sparkle 保留同一次手动安装请求；之后正常退出也可能继续安装并重启。不能承诺必须再次点击安装。应用仍禁自动检查、自动下载和静默发起安装；此标准延续行为需 Dan 在验收时确认。

### 不可写安装目录

独立 `.FN12ReadOnlyReview` 应用、服务、恢复路径及端口 18775，`Installed` 父目录为 `0555`。原生检查发现新版，点击安装后实际进入系统 `AuthorizationCopyRights`。工具明确禁止控制 SecurityAgent，因此由 Dan 处理系统窗口；Dan 回复已取消后，实际回读发现 build 12 已被同路径替换为 13。窄系统日志确认 11:17:50 此测试安装器实际获授权，并经 `/var/root/Library/Caches/<测试身份>/` 安装，不能把聊天中的取消动作当成 Sparkle 收到取消结果。此轮**不计为拒绝授权测试通过**；该路径仍待人工验收。build 13 strict codesign 通过，测试 PID 69996 已正常退出，测试父目录恢复为 `0755`。证据：`.build/FN12ReadOnlyValidation/permission-sample.txt`、`permission-result-before-user-reply.json`、`permission-result.json`、`auth-verified-timeline.txt`。真实安装目录及权限未改变，代理没有操作系统授权窗口。

另用 `.FN12ReadOnlyVolumeReview` 的独立 UDRO 镜像补测真正只读卷：介质、卷和 `statvfs ST_RDONLY` 均不可写。手动检查立即显示原生“无法更新，因为它打开自一个只读或临时位置”错误；“取消更新”返回编辑器、检查菜单恢复可用，build 12 与 strict 签名保持不变，没有进入系统授权。证据：`.build/FN12ReadOnlyVolumeValidation/{manifest.json,disk-info.plist,native-result.json}`。该项覆盖**只读卷预检拒绝**，不替代安装授权取消测试。应用正常退出，本次挂载已卸载，镜像和证据保留。

### 最终发布材料

最终 LocalTrial 包位于 `.build/FN12LocalTrialPin/Build/Products/Release/FinderNotes.app`，版本 `0.1.1（12）`。双 profile 最终构建、严格嵌套签名与手动更新配置检查通过，日志 `build-{standard,local-trial}-ime-guard.log`。

早期包在 `.build/FN12PreparedReleaseReview` 完成真实 ZIP 往返、官方 EdDSA 签名及应用公钥独立验证；加入最后输入保护之前的材料另保存在 `.build/FN12PreparedReleaseCandidateBeforeIMEGuard`，均不能作为最终发布包。Dan 允许系统钥匙串访问后，最终 `.build/FN12PreparedReleaseCandidate` 准备成功：ZIP 长度 **3,820,008 字节**，SHA256 `17d1aaafedabf00b74f859ef6f558a4bd6ed727d47faf8ec687b3b22202c1ea9`。另用 CryptoKit 与最终应用公钥独立验证 EdDSA，源／解压应用 strict codesign、124 项清单、固定 HTTPS URL、appcast 版本／长度／签名及中文 HTML 均通过。证据：候选目录的 `preparation.json`、`evidence/independent-verification.json`。私钥未导出；全部材料仅在本地，没有发布包或 feed。

## 后续授权的真实首次覆盖安装

2026-10-10，Dan 明确要求先覆盖当前 FinderNotes 供人工验收，保护草稿并正常退出旧版，暂不发布或执行 Git 收尾。操作前 CUA 应用列表及安装器进程检查均确认 LocalTrial 已退出，没有强制退出进程。恢复目录仅有空 `.lock`，没有待恢复 JSON；已复制到本次 0700 证据目录并逐项核对快照，不修改原目录或笔记。

已再次独立核验最终 ZIP EdDSA、SHA256 和源应用 124 项清单、严格签名，然后执行：

```sh
python3 -B scripts/install_local_trial.py \
  --source "$PWD/.build/FN12LocalTrialPin/Build/Products/Release/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app" \
  --replace-existing
```

安装器退出码 0，真实同路径 `0.1.0（11）` → `0.1.1（12）`，`oldApplicationDeleted=true`。安装后再次严格验签，应用清单与已验证源一致，恢复目录逐项不变，安装锁已移除。CUA 启动安装件，原生“关于”显示 `0.1.1 (12)`，应用菜单有“检查更新…”，仅一个 LocalTrial 进程；已返回主窗口供 Dan 测试。未打开或编辑用户媒体，也未用启动成功替代功能验收。

证据目录：`.build/FN12RealInstall-20261010-142424/`，含 `before.json`、`DraftRecovery-v1-before/`、`install-result.json`、`install-stderr.log`、`after-install-before-launch.json`、`launch-verification.json`。快照仅作本机保护，不上传。当前任务仍待人工验收；生产 feed 尚未发布，实际检查可能返回 404，应显示检查失败。

## Dan 人工验收环境准备

2026-10-10，按 Dan 后续要求准备尚未发布生产源时的人工流程，入口为 [FN12_ACCEPTANCE.md](FN12_ACCEPTANCE.md)。独立身份 `com.findernotes.FinderNotes.FN12Acceptance`、应用“FinderNotes 更新验收”、Finder 服务“FN12 验收更新（隔离副本）”、端口 18777、测试 keychain account 和两份合成 PNG；个人版仍为 12 且保持生产 HTTPS feed。准备过程中没有覆盖个人版、发布或 Git 收尾。

`.build/FN12Acceptance/verification.json` 独立确认 12／13 ZIP 的 Ed25519、CRC、strict codesign 和配置，74 个编译节与最终 LocalTrial 源一致。目标 13 ZIP 3,827,956 字节，SHA256 `169151a7f509bbd7f92aef3c960a3dfb9c78a2345b738903a3d29b7396efbba3`。控制台 `acceptance_console.py` 仅监听 loopback，提供固定场景、严格限定合成图权限按钮和安装前后核验，含 Host／Origin／CSRF 限制；不会保存正文、启动安装或修改生产源。

HTTP 与语法 smoke 共 13 项检查通过（`.build/FN12Acceptance/evidence/console-smoke.json`），但慢下载只读首段后客户端未可靠关闭，服务器随后发送完毕，不能算下载取消验证通过。该准备专用传输标记保存在 `console-smoke-transfer-marker.json`，已解除其对后续人工场景的保守冻结；没有清 Sparkle 缓存或降级应用。此前独立真实 Sparkle 网络取消证据仍按原记录，不与本轮 HTTP 检查混用。

`verify_acceptance.py` 固定范围、显式一次性基线、只读 xattr 和精确进程检查，清理观察最多 120 秒；12 项初始边界检查和取消退出 receipt 候选调整的 11 项边界检查通过，不代替真实安装。取消退出的 receipt 只有严格绑定且当前旧 inode 未变时才可提前观察；多候选保留 unknown，missing 本身不证明清理。

已启动验收应用构建 12，控制台当前可操作；尚未记录人工正文基线或执行本轮原生下载／安装。原生 latest 检查实际产生 appcast 请求，但 CUA 后续菜单操作不能稳定确认提示窗口，故本轮不记原生 UI 通过，也不据此判定产品失败；留给 Dan 在该独立环境操作。现有最新版、中文、草稿、清理等历史实测与未验证边界保留，任务仍 Review。

最终核验另增加旧 PID 独立存在查询：只用信号 0 查询，不结束进程；权限拒绝视为仍运行，其他查询错误保留 unknown。必须所有基线 PID 不存在且有一个不同的新 PID 才确认重启，20 项注入边界检查通过。

## 失败记录与证据边界

接入初期的源引用缺失、冗余 Sparkle embed 阶段，以及 Swift 6 对 Sparkle 非隔离 delegate 的 conformance 错误均曾使构建失败；已修正，原日志保留在 `.build/FN12Dependencies`。首次组件 harness 的编译参数和旧 AppKit 调用问题亦已修正，保留尝试日志。构建完成前的一次发布材料准备被严格签名检查拒绝，没有发布材料。

真实 UI 另发现“最新版提示中直接 CmdQ”可使 AppKit 嵌套 modal loop 等待 MainActor 异步退出回复而卡住，样本在 `.build/FN12ValidationPin/ambiguous-app-sample.txt`。已增加 modalWindow 早期同步拒绝退出保护，真实 modal session 组件回归及修复后的原生窗口操作通过。仅该无文件、无用户草稿的隔离挂起 PID 57568 曾在核对精确可执行路径后终止；真实 LocalTrial 未被强制退出。

首次审计把 URL 的目录尾斜杠语义当成路径不一致，真实 receipt 出现六次 `unreadable`；已改为标准化路径比较并再次完成真实更新。保留原 receipt，不追改旧证据。审计文件读取与已有对象写入检查中发现的 FIFO、超大文件、链接和异常观测序列问题也已修正并回归。

真实中文选词、组合输入阻止退出与中文正文独立回读已按上文实测；跨 Sparkle 窗口的候选上下文延续、系统安装授权取消、真实保存 I/O 恰在进行中的安装竞态仍待 Dan 验收。中文／emoji 完整正文的真实编辑、保存、导出已有独立证据。组件 marked text、saving flag 与只读卷预检不能替代剩余路径。

生产 feed 尚未发布时返回 404 属于真实错误；不能据此宣称已具备生产更新服务。Developer ID、Apple 公证、真实网络下载后的 Gatekeeper、Intel 运行及 FN08-I07／I08 原结论均不由本轮自动测试覆盖。真实首次覆盖安装已按上述后续授权完成；正式发布和 Git 收尾继续留待明确授权。
