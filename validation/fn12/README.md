# FN-12 隔离更新验证

这些工具调用产品原始 Swift 源与 Sparkle 2.10.0 官方工具，不实现另一套更新器。产物位于本工作树的 `.build/FN12*` 独立目录。正式 LocalTrial 应用、生产 feed 与生产签名密钥不用于测试。

## Dan 人工验收入口

已准备的 `.build/FN12Acceptance` 使用独立“FinderNotes 更新验收”、localhost:18777、合成 PNG 和浏览器控制台。按 [FN12_ACCEPTANCE.md](../../docs/FN12_ACCEPTANCE.md) 执行最新版／失败／取消，再完成真实 12 → 13。控制台 `acceptance_console.py` 提供固定场景及保存后基线／重启后核验按钮；`verify_acceptance.py` 只读取该验收身份、精确安装路径与自有 xattr，生成证据，不安装、不退出、不删除旧应用。基线不能自动创建或覆盖。

此 variant 的准备命令为 `python3 -B validation/fn12/prepare_review.py --variant acceptance --input-app .build/FN12LocalTrialPin/Build/Products/Release/FinderNotes.app --sparkle-tools .build/FN12Dependencies/Sparkle/bin`，已有目录会拒绝覆盖；不要用它重置进行中的人工验收。

## 组件检查

```sh
zsh validation/fn12/run_components.sh
```

编译实际产品源并替换 `main`，使用 Swift 6 与同一 Sparkle 框架。应用子类只截获异步退出回复；controller 窗口隐藏、恢复存储为 nil，不调用 `applicationDidFinishLaunching`，不注册 Finder 服务。程序化 marked text 仅说明组件保护，不能替代真实中文输入法候选验收。结果保留在 `.build/FN12Validation/components/`。

组件同时创建真实 AppKit modal session，验证 modal alert 中退出同步取消、不会等待异步回复，结束 modal 后仍能使用原有草稿退出链。审计用合成 Bundle、严格限定的测试缓存和 JSON，覆盖唯一绑定、保守完成评估、目录 inode、symlink/FIFO/超大文件拒绝与安全持久化；这些合成记录不代表真实 Sparkle 旧应用清理已经完成。

## 双版本与测试 feed

先完成带 Sparkle 的普通 Release 构建，再执行：

```sh
python3 validation/fn12/prepare_review.py \
  --input-app .build/FN12Standard/Build/Products/Release/FinderNotes.app \
  --sparkle-tools .build/FN12Dependencies/Sparkle/bin
python3 validation/fn12/fixture_server.py
```

准备程序复制版本 `0.1.1（12）` 与 `0.1.2（13）`，为独立身份 `com.findernotes.FinderNotes.FN12Review` 写入独立服务 `FN12 测试更新（隔离副本）` / `FinderNotesFN12Review`。官方 `generate_keys` 使用独立钥匙串 account `com.findernotes.FN12Review`；私钥不导出。修改后的 review host 重新本机签名，并严格核验嵌套签名；官方 `sign_update` 签署每个 ZIP。存在相同产物时拒绝覆盖。

测试应用仅给 `localhost` 允许 HTTP，feed 固定为 `http://localhost:18772/appcast.xml`。正式应用仍使用 HTTPS，没有增加生产 ATS 例外。测试恢复目录由独立 Bundle ID 自动隔离。准备程序不启动应用、不注册服务；由操作者显式启动 `Installed/FinderNotes FN12 Review.app`。

只读安装目录使用预定义独立 variant：

```sh
python3 -B validation/fn12/prepare_review.py --variant readonly \
  --input-app .build/FN12StandardPin/Build/Products/Release/FinderNotes.app \
  --sparkle-tools .build/FN12Dependencies/Sparkle/bin
python3 -B validation/fn12/fixture_server.py --variant readonly
```

该 variant 固定输出 `.build/FN12ReadOnlyValidation`，应用 `Installed/FN12 ReadOnly Review.app`，身份 `com.findernotes.FinderNotes.FN12ReadOnlyReview`，端口 `18775`。仍使用独立测试 keychain account，服务名/端口另行隔离；不改变普通测试状态。工具不自动改变目录权限；本轮操作者已在生成后将应用的 `Installed` 父目录设为 `0555`。复用时先明确确认目标路径，再由操作者设置/恢复该测试目录权限，不能更改正式安装目录。

`0555` 目录仍可通过 macOS 明确授权由 Sparkle 的系统安装器替换，不能把目录权限当作只读卷。若只验证原生只读卷预检，先准备上述 readonly variant 的版本 12，再运行：

```sh
python3 -B validation/fn12/prepare_readonly_volume.py
```

脚本固定输出 `.build/FN12ReadOnlyVolumeValidation`，复制既有测试版本，设置独立身份 `com.findernotes.FinderNotes.FN12ReadOnlyVolumeReview` 和独立 Finder 服务，保留既有测试公钥与 localhost feed；本机签名后创建 UDRO 镜像，以 `readonly/nobrowse` 挂载到该目录下的 `Mount`，核对严格签名、卷/介质不可写与 `statvfs` 只读标志。不会启动应用、访问钥匙串或交互授权。存在输出时拒绝覆盖，清理须在确认测试应用退出后由操作者处理。

挂载设备和完整应用路径记录于该目录的 `manifest.json`。由操作者手动打开挂载应用并检查更新；Sparkle 2.10.0 通过 `statfs` 的 `MNT_RDONLY` 在加载 appcast 之前报告 `SURunningFromDiskImageError (1003)`。该测试仅证明只读卷预检拒绝，不证明系统授权取消或下载后安装失败。

在另一终端切换下一次请求的情形，无需重启测试应用：

```sh
python3 validation/fn12/fixture_server.py --set-case latest
```

| case | 测试目的 |
| --- | --- |
| `update` | feed 提供真实已签名构建 13；安装 12 时应发现新版 |
| `latest` | feed 构建号与 Installed 当前构建号一致 |
| `local-ahead` | feed 构建号比 Installed 当前构建号小 1 |
| `404` | feed 返回 HTTP 404 |
| `invalid` | feed 返回损坏 XML |
| `timeout` | feed 故意 90 秒不回复，观察原生网络超时 |
| `bad-signature` | 正常 ZIP 配不正确 EdDSA 签名；必须在解压前拒绝 |
| `corrupt` | 非 ZIP 字节配正常包签名；必须拒绝且保留旧版 |
| `slow-download` | 已签名 ZIP 每半秒只发送 4 KiB，供取消下载验证 |

离线测试直接停止测试 server，再手动检查；重新启动 server 后可重试。server 只监听 `127.0.0.1`，只提供清单里的测试 ZIP；请求与取消记录保留在 `requests.log`，不会记录私钥。

## 真 Sparkle 无界面网络矩阵

```sh
python3 -B validation/fn12/run_network.py
```

这个独立 harness 使用真实 `SPUUpdater`，custom user driver 只记录回调并选择取消/拒绝安装。它不使用产品的原生窗口，不能替代原生 UI 验收。正常新版在发现后 dismiss；只有签名错误或损坏包会完整下载，任何安装就绪回调均 skip。慢下载收到首段数据后取消，不执行应用替换或重启。

矩阵使用独立端口 `18773`、无监听端口 `18774` 模拟断线，以及每病例独立身份 `com.findernotes.FinderNotes.FN12NetworkChecks.<case>`。复用隔离测试公钥，不创建额外密钥，也不更改 UI 测试 feed 的状态。Sparkle 自身可能在上述独立身份的系统缓存目录创建安装缓存；源码及证据在 `.build/FN12Validation/network`。

断线、404、XML 错误与超时必须进入错误回调，不能进入最新版回调；等号和本地领先分别检查 Sparkle 的 no-update reason。错误签名/损坏包检查真实 `SUValidationError` 与 EdDSA 错误链；`preparing-extraction` 是 Sparkle 的进度回调名称，实际错误链明确说明验证发生在解压之前。所有病例同时核对检查中禁止再次检查、结束后恢复可检查。超时由 Sparkle 原生网络超时触发，harness 的 75 秒只用于防止验证无限等待。

## 真实界面流程与证据

1. 从 Installed 的构建 12 启动，核对应用身份、恢复路径、菜单“检查更新…”，先检查最新版与本地领先，再依次检查 404、损坏 XML、离线、超时，确认不会误报最新版。
2. 用独立测试服务打开本次合成 PNG，写入中文与 emoji。置顶后执行检查、下载、签名失败及取消；读取原文件 xattr 比较完整正文。保存中、导出面板和真实中文输入候选期间尝试重启，确认仍使用现有保护。
3. feed 切为 update，下载到安装就绪。让草稿需要确认，点击安装重启后选择“返回编辑”，确认进程、草稿、恢复记录保留；再次安装并明确处理草稿后允许退出。
4. 记录旧 PID、原安装路径与构建号；完成后核对原 PID 结束、同路径构建 13 重启、严格 codesign 通过；检查 Sparkle 本次临时目录以确认旧应用清理，不能仅凭版本变化认定清理完成。
5. 安装目录不可写需要另一个隔离的只读副本或挂载，记录 Sparkle 实际拒绝/授权提示。不能在真实 LocalTrial 目录上改变权限，不能绕过系统阻挡。

以上是操作步骤，执行结果单独记入正式任务的交付记录。脚本生成、编译通过、签名检查及 HTTP 响应不等同于真实安装、重启、中文输入法或系统权限验证。
