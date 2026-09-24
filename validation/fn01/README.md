# FN-01 原生注释验证探针

此目录只服务 [FN-01](https://app.notion.com/p/3e4e7607d649813aacf2f840d92e5e03)。探针不提供产品编辑界面。它通过固定 AppleScript 调用 Finder `item.comment`，用 UTF-8 字节、SHA-256 和计时核对结果。Finder“显示简介”的实际显示、编辑与文件操作需要另外在 Finder 中完成，不能由脚本往返结果代替。

## 本机运行

从仓库根目录执行：

```sh
./scripts/verify_toolchain.sh
./validation/fn01/build.sh
"${TMPDIR:-/tmp}/findernotes-fn01-probe" prepare
```

`prepare` 打印本轮 `ROOT`。将其完整路径赋给下方 `fn01_root`；不要照抄示例占位值。根目录位于 macOS 临时目录，包含 `.fn01-owned` 标记、生成的 PNG/MOV 种子、`work/` 副本和 `moved/` 目录。探针只允许在 `work/`、`moved/` 内的 PNG/MOV 副本上操作。MOV 由本机 Homebrew FFmpeg 生成；当前工具要求 `/opt/homebrew/bin/ffmpeg`。不要把根目录指向真实素材或旧 Orbit。

```sh
probe="${TMPDIR:-/tmp}/findernotes-fn01-probe"
fn01_root='/把 prepare 输出的 ROOT 完整路径粘贴到这里'
"$probe" read "$fn01_root" work/mixed.png
"$probe" read "$fn01_root" work/mixed.png initial
"$probe" write-verify "$fn01_root" work/mixed.png mixed
"$probe" write-verify "$fn01_root" work/cjk2000.png cjk2000
"$probe" write-verify "$fn01_root" work/utf8-16k.png utf8-16k
"$probe" read "$fn01_root" work/mixed.png mixed '〔Finder编辑-FN01〕'
```

`read` 不带样本时只记录实际字节数、SHA-256、耗时和媒体哈希；带样本时逐字节核对。最后一个可选参数是 Finder 手工追加的原样后缀。`write-verify` 写入后重新从 Finder 读取，并确认媒体数据内容仍与本轮种子相同。错误退出码为非零；读取错误绝不当作空注释。每次运行都记录真实命令与输出，不用编译结果替代 Finder 实测。

文本样本由代码生成并以 UTF-8 保存到本轮根目录：`mixed.txt`（中文、emoji、换行、首尾空白、引号、反斜杠）、`cjk2000.txt`（约 2,000 中文字符）、`utf8-16k.txt`（精确 16,384 字节）及 `initial.txt`。字节数只是测试点，不表示系统容量上限。两个媒体类型各有独立副本，方便保存不同样本和人工复查。

## Finder 手工阶段

1. 在程序写入前，打开本轮 `work/mixed.png` 与 `work/mixed.mov` 的“显示简介”，将“注释”设为 `FN-01 已有注释：中文🙂 末尾`；关闭简介窗口。分别以 `read <ROOT> work/mixed.png initial` 和 `.mov` 核对已有注释。
2. 对两类媒体的三个样本分别运行 `write-verify`。在 Finder“显示简介”检查每个副本的注释；移至注释正文末尾，追加 `〔Finder编辑-FN01〕`，结束编辑并关闭窗口，再运行带样本及该后缀的 `read`。保留首尾空白、换行原样；任何规范化或截断都是失败结果。
3. 对 `work/lifecycle.png` 与 `.mov` 写入 `mixed`，关闭探针。在 Finder 中改名为 `renamed.png` / `renamed.mov`，移入本轮 `moved/`，复制一份并将副本命名为 `copy.png` / `copy.mov`。分别从新路径读取并核对 `mixed`；仅将副本改写为 `cjk2000`，再次读取原件与副本。各次 `read` 也核对媒体内容哈希与设备／inode 身份。
4. 记录 Finder 界面可见响应、权限提示与是否允许。终端或当前命令身份的授权，不等于未来正式应用的授权；服务入口、拒绝授权及多选行为由 FN-02 验证。

## 已观察到的操作路径差异

2026-09-24 在本机 APFS 临时目录中，Finder UI 移动 MOV 保留注释，但命令行同卷 `mv` 对新建 PNG 和 MOV 测试副本都使 Finder 注释读回为空，媒体内容 SHA-256 和 inode 不变。复现时在新的 `prepare` 根目录中分别复制一个种子到 `work/mv-probe.png` / `.mov`，先运行 `write-verify ... mixed`，再用 `mv` 移入同轮 `moved/`，最后运行带 `mixed` 期望的 `read`。两类媒体在移动后均返回非零并报告实际 0 字节。不要将文件系统移动结果等同于 Finder UI 移动；也不要把空文本自动解释为用户主动删除注释。实际日志与限制见 [本机证据](../../docs/evidence/fn01/2026-09-24.md)。

临时目录仅在本轮证据核对完后清理，且只清理本次 `prepare` 创建的目录。Git 保存合成数据的哈希、实际命令和日志，不提交临时媒体及本机私有信息。
