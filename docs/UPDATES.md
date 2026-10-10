# FinderNotes 个人版应用内更新

本功能采用固定的 Sparkle 2.10.0。应用菜单 **FinderNotes → 检查更新…** 只在用户点击后检查，显示当前版本或新版说明；下载失败与检查失败单独显示错误。检查、下载和安装期间不会发起重复检查。首次带更新器的版本是 **0.1.1（12）**，沿用 `com.findernotes.FinderNotes.LocalTrial`、`FinderNotesLocalTrial` 服务端口和原草稿恢复目录。这仍是个人稳定版开发，源码公开与 Release 发布不代表 V1.0 最终验收完成。

安装重启经过现有异步退出链。组合输入尚未完成时直接延后退出，提示先完成输入，不打开草稿确认框；保存或导出尚未完成时亦不强制退出。未保存草稿选择“返回编辑”会保留当前运行实例，可通过“检查更新…”重新打开已下载的安装界面。**已经点击“安装并重启”后，Sparkle 会保留同一次手动安装请求；之后正常退出也可能继续安装并重启。**不能把返回编辑理解为撤销已请求的安装。更新界面不操作媒体正文或草稿恢复目录。FN08-I07、FN08-I08 仍按原记录保留；跨 Sparkle 窗口的原候选上下文延续尚待人工验收，不能因加入更新器认定已解决。

## 更新源、签名与本地准备

FN-13 按 Dan 授权将源码、更新列表和安装包统一到公开仓库 [`danding9717/FinderNotes`](https://github.com/danding9717/FinderNotes)。新应用的生产 feed 固定为该仓库 `updates` 分支中的：

```text
https://raw.githubusercontent.com/danding9717/FinderNotes/updates/appcast.xml
```

`updates` 分支只承载发布数据，可在核验安装包后独立更新；应用源码改动通过 PR 审阅，待 Dan 实际验收后再按授权合并。迁移期间旧源 `https://raw.githubusercontent.com/danding9717/FinderNotes-updates/main/appcast.xml` 保持可用，具体切换顺序见下文。

应用仅嵌入 Ed25519 公钥。私钥存于登录钥匙串，签名 account 为 `com.findernotes.FinderNotes.LocalTrial.updates`。迁移保持原 bundle ID、服务身份和签名密钥。不要重新生成、导出或把私钥写进仓库。应用启用解压前验签；构建号是递增的正整数，Sparkle 据此比较版本。[Sparkle 官方接入说明](https://sparkle-project.org/documentation/)

先构建产物，再生成新的本地待审目录：

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-release" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh

python3 -B scripts/prepare_update.py \
  --source "$PWD/.build/DerivedData-release/Build/Products/Release/FinderNotes.app" \
  --output "$PWD/.build/update-review-single-repo" \
  --sign-update "/path/to/Sparkle-2.10.0/bin/sign_update"
```

将 `--sign-update` 的示例路径替换为固定 Sparkle 2.10.0 的官方工具路径；可在 Xcode SPM 下载产物的 `artifacts/sparkle/Sparkle/bin` 查找。准备脚本读取构建 app 内的版本，不改 Info.plist；使用 `ditto` 生成 ZIP、解压复验完整清单及严格代码签名，保存框架内部合法链接和执行权限。然后调用官方签名工具，并用 app 内公钥独立验证签名，防止选错钥匙串账号。[Sparkle 官方发布说明](https://sparkle-project.org/documentation/publishing/)

本地输出包括版本 ZIP、`SHA256SUMS`、中文说明、`appcast.xml` 和 `preparation.json`。默认 tag 为 `v{version}`，例如桥接版的下载地址是 `https://github.com/danding9717/FinderNotes/releases/download/v0.1.3/FinderNotes-0.1.3-14.zip`，不用 `latest`。中文更新说明内嵌于 appcast 的 `description`，不依赖独立 HTML 附件。Release 只上传 ZIP 与 `SHA256SUMS`；构建、复现和验证材料归档至源码仓库的 `docs/releases/<version>-<build>/`，GitHub 自动生成的源码 ZIP、tar.gz 仍会显示。

可用 `--notes-file` 提供 UTF-8 纯文本，每行作为一段；`--release-base-url` 检查 HTTPS 地址，自定义值须由调用者保证是固定版本下载目录。输出已存在时停止，不覆盖，每次准备应使用新目录。失败打印 `evidenceDirectory` 并保留本次现场；`prepared_locally` 只表示本地准备成功，没有上传、提交或发布。

## 首次升级安装

历史 0.1.0（11）没有更新器，首次须明确授权后执行一次 bootstrap；本机真实 11 → 12 已于 2026-10-10 完成并验收。其他安装或后续显式替换仍先保护未保存内容，并**正常退出所有 LocalTrial 副本**。脚本不杀进程，不强制丢弃草稿。

首次安装的默认行为仍拒绝覆盖任何已有对象：

```sh
python3 -B scripts/install_local_trial.py \
  --source "$PWD/.build/DerivedData-release/Build/Products/Release/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app"
```

只有明确升级才使用：

```sh
python3 -B scripts/install_local_trial.py \
  --source "$PWD/.build/DerivedData-release/Build/Products/Release/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app" \
  --replace-existing
```

升级要求新旧均为严格签名校验通过的 LocalTrial app，服务身份一致且新构建号更大。拒绝路径符号链接、包内逃逸链接、运行实例、并行安装锁、源或目标变化及并发发布碰撞。包内普通版本化框架链接允许保留。复制后先复验新包，再将旧包放入本次私有临时目录，独占发布新包到同一路径并再次验证；成功后直接删除旧包，不放废纸篓、不留下回退副本、不查找其他目录。

失败退出码为 1；若应用已安装并验证，但安装锁清理失败，状态为 `incomplete`，并保留 `installationVerified`、`oldApplicationDeleted` 与 `lockCleanupError`。原安装错误和锁清理错误同时发生时保留原主因及两者证据。结果包含 `stagingDirectory`、`previousApplication` 等现场路径。新包已发布但旧包删除失败也报告失败，不写“完成”。不要自动重复、手动删除现场或清理草稿；先核对打印出的路径及当前安装状态。脚本不会自动回滚，以免覆盖失败过程中出现的新对象。锁只约束此安装器；最终进程核验不能原子地阻止其他进程在检查后自行启动应用。

bootstrap 只核验复制与安装结果，不自动启动应用。首次启动以及后续从网络下载后的系统安全提示必须实测。本版本仍采用本机 ad hoc 签名，未进行 Developer ID 签名与 Apple 公证。遇系统阻挡保留提示与摘要，不改 Gatekeeper、TCC 或 quarantine 设置。

## 应用内更新后的清理核验

Sparkle 2.10.0 安装器会直接移除临时新／旧应用目录，清理调用使用 `error:NULL`，没有向应用提供清理错误回调。因此“检查流程结束”或“新版已重启”都不能单独证明旧应用已清理；检查流程正常结束还可能表示没有更新、忽略或跳过更新。[官方清理实现](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/SUPlainInstaller.m#L396-L406)，[官方更新流程回调说明](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdaterDelegate.h#L457-L475)

FinderNotes 在允许退出前记录本次目标版本、原安装路径、旧应用文件身份和能唯一绑定的本次 Sparkle 缓存路径。重启后只读核验当前应用身份下 `~/Library/Caches/<bundleID>/org.sparkle-project.Sparkle/Installation/` 的本次目录，最多检查三层，不扫描其他应用缓存、其他安装件或系统替换目录。每份待核验记录约在 15 秒内有限重试，记录以下结果：

- `completed`：目标版本已在原安装路径运行，在本次绑定位置先观察到旧应用的设备／inode，随后该路径消失，且这段观测中没有身份变化或读取异常。这是限定路径的核验结果，不代表扫描或清理了其他目录。
- `incomplete`：有限复核结束时，本次绑定位置仍存在旧应用的同一设备／inode。记录观察时刻和证据，不把它写成已经清理。
- `unknown`：没有形成可确认的观测链，例如无法唯一绑定本次目录、重启后缓存已经消失而从未看到旧应用、路径身份变化、读取异常，或运行版本／路径与目标不符。`unknown` 表示无法确认，**不等同实际清理失败**。

选择“返回编辑”或因组合输入而延后退出时，只记 `termination-cancelled`／`unknown`，保留同一运行实例，不强制退出。Sparkle 保留已请求的安装，可再次手动重试，也可能在之后正常退出时继续。[官方等待退出与安装实现](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/AppInstaller.m#L392-L415) 审计只写自己的结果记录，不删除旧包、缓存、媒体正文或恢复草稿；旧包删除仍由 Sparkle 执行。不能确认时保留现场，不扩大目录搜索或自动补删。

记录位于 `~/Library/Application Support/<bundleID>/UpdateResults/<UUID>.json`，新建结果目录为 0700，记录为 0600。读取拒绝符号链接、硬链接、非普通文件和超过 64 KiB 的记录；已有目标必须是同一审计记录才可更新，未知对象保留。记录失败只写系统日志并保持无法确认，不据此报告清理成功。审计记录是本机证据，不取代 Sparkle 错误提示、真实安装验收或 Notion 任务状态。

## 单仓迁移与发布验收

本次迁移由 [FN-13](https://app.notion.com/p/3f5e7607d64981659145f36b04d7b241) 记录范围与验收。以下为发布和验证顺序。2026-10-10 已完成真实 13→14→15 安装与重启，15 的新源检查显示当前最新版本，见[实测记录](evidence/fn13/real-upgrade-verification.json)；旧库删除结果另行记录：

1. 从迁移 PR 的固定源码提交构建 **0.1.3（14）**；再以同一实现、仅版本及说明差异构建 **0.1.4（15）**。两个版本均内嵌主仓 `updates` 分支的新 feed，保留已有应用身份与签名密钥。记录实际提交、安装包 SHA256、长度和签名，不以分支名代替构建来源。
2. 主仓公开后先发布两个固定版本的 ZIP 与校验文件，匿名下载复验字节、签名和包内配置；新 feed 提供 15，旧 feed 只提供 14 作为迁移入口。旧 feed 的 14 安装包也从主仓 Release 下载，避免依赖旧仓附件。不能让旧 feed 直接提供 15，否则无法凭这次安装证明新 feed 可用。
3. Dan 在原安装件中通过“检查更新…”完成 **13 → 14**，重启后确认版本及新 feed；再检查更新并完成 **14 → 15**，确认原路径运行、检查和安装正常。最后在 15 中再次检查更新。只有 14 显示“已是最新版本”不足以证明新源能安装更新；脚本下载与验签也不替代真实应用内升级。
4. 保留 `FinderNotes-updates`，直到 Dan 完成上述升级并明确确认新源检查、安装正常。删除前核对新 feed、保留版本安装包和更新说明均不再依赖旧仓，并记录真实验证结果。未升级的旧版仍依赖旧 feed；删除后的剩余旧安装件需手动安装主仓发布包。

发布顺序始终是先核验固定版本安装包，再更新 feed 并匿名回读精确 URL。脚本生成单版本 appcast；合并发布数据时保留需要支持的历史条目，逐项核验引用，不用新文件直接覆盖历史。历史 13 若保留，须指向主仓的同字节安装包并复验签名。HTTP 404、检查失败或下载失败均应如实报告，不能显示或记录为最新版。

FN-12 历史验收使用的 `0.1.1（12）` 保留包来自独立验收提交 `c2f4253`，不含后来整合的 FN-11；该记录不代表当前安装件或本次迁移包。历史证据继续保留，不将本次地址变更追写为历史实测结果。

验收时自动测试只使用独立临时目录、合成 bundle 和签名／进程注入。测试源码已按收尾授权从当前树移除，以下历史命令须在清理前提交 `c2f425371441af21d542856e2db6a854677ecf57` 的独立副本中运行：

```sh
/usr/bin/python3 -B -m unittest discover -s tests -p 'test_update_tools.py' -v
```

这些测试覆盖首次拒绝覆盖、显式升级、构建号与身份拒绝、路径与符号链接、并发碰撞、源变化、签名失败、发布后复验失败、旧包清理失败及真实 `ditto` ZIP 往返。注入测试不证明真实签名、真实 UI、进程退出或系统安全行为。

交付还须在独立应用身份、目录和测试 feed 中核验检查、下载、解压前验签、返回编辑、重试安装、同路径替换、重启与旧包清理；分别记录断网、超时、404、元数据错误、损坏包、错误签名、取消下载、不可写目录。未保存草稿、真实中文候选、保存／导出进行中、置顶窗口操作，以及媒体自有 xattr 正文的独立回读均需单独留证。编译或脚本通过不替代这些真实行为验收。
