# FinderNotes 个人版应用内更新

本功能采用固定的 Sparkle 2.10.0。应用菜单 **FinderNotes → 检查更新…** 只在用户点击后检查，显示当前版本或新版说明；下载失败与检查失败单独显示错误。检查、下载和安装期间不会发起重复检查。首次带更新器的版本是 **0.1.1（12）**，沿用 `com.findernotes.FinderNotes.LocalTrial`、`FinderNotesLocalTrial` 服务端口和原草稿恢复目录。这仍是个人稳定版开发，不代表 V1.0 最终版或公开发布完成。

安装重启经过现有异步退出链。组合输入尚未完成时直接延后退出，提示先完成输入，不打开草稿确认框；保存或导出尚未完成时亦不强制退出。未保存草稿选择“返回编辑”会保留当前运行实例，可通过“检查更新…”重新打开已下载的安装界面。**已经点击“安装并重启”后，Sparkle 会保留同一次手动安装请求；之后正常退出也可能继续安装并重启。**不能把返回编辑理解为撤销已请求的安装。更新界面不操作媒体正文或草稿恢复目录。FN08-I07、FN08-I08 仍按原记录保留；跨 Sparkle 窗口的原候选上下文延续尚待人工验收，不能因加入更新器认定已解决。

## 更新源、签名与本地准备

公开仓库 [`danding9717/FinderNotes-updates`](https://github.com/danding9717/FinderNotes-updates) 仅用于版本信息、中文更新说明及已编译更新包。源码仓库保持私有。生产 feed 固定为：

```text
https://raw.githubusercontent.com/danding9717/FinderNotes-updates/main/appcast.xml
```

应用仅嵌入 Ed25519 公钥。私钥存于登录钥匙串，签名 account 为 `com.findernotes.FinderNotes.LocalTrial.updates`。不要重新生成、导出或把私钥写进仓库。应用启用解压前验签；构建号是递增的正整数，Sparkle 据此比较版本。[Sparkle 官方接入说明](https://sparkle-project.org/documentation/)

先构建产物，再生成新的本地待审目录：

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build12" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh

python3 -B scripts/prepare_update.py \
  --source "$PWD/.build/DerivedData-build12/Build/Products/Release/FinderNotes.app" \
  --output "$PWD/.build/update-review-0.1.1-12" \
  --sign-update "$PWD/.build/FN12Dependencies/Sparkle/bin/sign_update"
```

`--sign-update` 应指向固定 Sparkle 2.10.0 的官方工具。也可在 Xcode SPM 下载产物的 `artifacts/sparkle/Sparkle/bin` 查找。准备脚本读取构建 app 内的版本，不改 Info.plist；使用 `ditto` 生成 ZIP、解压复验完整清单及严格代码签名，保存框架内部合法链接和执行权限。然后调用官方签名工具，并用 app 内公钥独立验证签名，防止选错钥匙串账号。[Sparkle 官方发布说明](https://sparkle-project.org/documentation/publishing/)

输出包括版本 ZIP、`SHA256SUMS`、中文 HTML 说明、`appcast.xml` 和 `preparation.json`。默认 ZIP 地址是固定版本的 `releases/download/v0.1.1-12/FinderNotes-0.1.1-12.zip`，不用 `latest`。可用 `--notes-file` 提供 UTF-8 纯文本，每行作为一段；`--release-base-url` 检查 HTTPS 地址，自定义值须由调用者保证是固定版本下载目录。输出已存在时停止，不覆盖。失败打印 `evidenceDirectory` 并保留本次现场；`prepared_locally` 只表示本地准备成功，没有上传、提交或发布。

## 首次升级安装

历史 0.1.0（11）没有更新器，首次须明确授权后执行一次 bootstrap；本机真实 11 → 12 已于 2026-10-10 完成并验收。其他安装或后续显式替换仍先保护未保存内容，并**正常退出所有 LocalTrial 副本**。脚本不杀进程，不强制丢弃草稿。

首次安装的默认行为仍拒绝覆盖任何已有对象：

```sh
python3 -B scripts/install_local_trial.py \
  --source "$PWD/.build/DerivedData-build12/Build/Products/Release/FinderNotes.app" \
  --destination "$HOME/Applications/FinderNotes.app"
```

只有明确升级才使用：

```sh
python3 -B scripts/install_local_trial.py \
  --source "$PWD/.build/DerivedData-build12/Build/Products/Release/FinderNotes.app" \
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

## 后续发布与验收

本轮已交付隔离验证和可审阅材料，完成真实首次覆盖安装并获 Dan 验收，标准 Git 收尾另按授权执行。正式 GitHub Release 和生产 appcast 上传仍待明确发布授权。发布时先上传固定版本 ZIP 与 HTML，核验下载字节、签名和中文说明，再更新生产 feed 并回读。脚本生成的是单版本 appcast；后续版本发布时须与已发布 feed 合并，保留需要支持的旧版本条目，再次核验所有引用，不直接覆盖历史。生产 feed 没有发布前，检查可能返回 HTTP 404，必须保留为失败，不能显示最新版。

验收时自动测试只使用独立临时目录、合成 bundle 和签名／进程注入。测试源码已按收尾授权从当前树移除，以下历史命令须在清理前提交 `c2f425371441af21d542856e2db6a854677ecf57` 的独立副本中运行：

```sh
/usr/bin/python3 -B -m unittest discover -s tests -p 'test_update_tools.py' -v
```

这些测试覆盖首次拒绝覆盖、显式升级、构建号与身份拒绝、路径与符号链接、并发碰撞、源变化、签名失败、发布后复验失败、旧包清理失败及真实 `ditto` ZIP 往返。注入测试不证明真实签名、真实 UI、进程退出或系统安全行为。

交付还须在独立应用身份、目录和测试 feed 中核验检查、下载、解压前验签、返回编辑、重试安装、同路径替换、重启与旧包清理；分别记录断网、超时、404、元数据错误、损坏包、错误签名、取消下载、不可写目录。未保存草稿、真实中文候选、保存／导出进行中、置顶窗口操作，以及媒体自有 xattr 正文的独立回读均需单独留证。编译或脚本通过不替代这些真实行为验收。
