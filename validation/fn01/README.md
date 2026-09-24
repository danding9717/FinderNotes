# FN-01 自定义 xattr 验证

仅服务 [FN-01](https://app.notion.com/p/3e4e7607d649813aacf2f840d92e5e03)，不提供产品编辑器或系统服务。当前路线见 Notion 的 D-006。原 Finder 注释探针 `FN01.swift` / `build.sh` 保留，原操作说明移至 [FINDER_COMMENT_HISTORY.md](FINDER_COMMENT_HISTORY.md)，历史证据不改写。

## 运行隔离矩阵

需要完整 Xcode、本机 Python 3，以及 `/opt/homebrew/bin/ffmpeg`（仅生成合成 MOV，不接触真实媒体）。从仓库根目录运行：

```sh
./scripts/verify_toolchain.sh
./validation/fn01/build-xattr.sh
python3 validation/fn01/run-xattr.py > /tmp/fn01-xattr-run.jsonl
```

构建器默认输出 `${TMPDIR}/findernotes-fn01-xattr-probe`。矩阵默认使用该程序，也支持 `--probe /absolute/path`。每次运行由 `prepare` 新建系统临时目录 `findernotes-fn01-xattr-UUID`；日志中的 `finder-ready` 包含本轮根路径。根内有专用标记、PNG/MOV 种子、`work/`、`moved/`、样本文本及 Finder 基线文件。不要向根内放真实素材；不要把旧实验根或素材库当作本轮根。

矩阵通过实际 Swift 系统调用和独立 `/usr/bin/xattr` 工具交叉核对：

- PNG/MOV 的混合文本、2,000 中文字符、16 KiB、零字节正文；结束写入进程后重新读取。
- 属性缺失与零字节正文不同；权限读取失败、非法 UTF-8 都报错。
- 独立工具先写，探针读回；探针写后，独立工具逐字节比对。
- `/bin/mv` 改名与同卷移动、`/bin/cp -p` 复制；记录设备/inode，复制后独立改写。
- 每次存储修改前后核对媒体内容 SHA-256 及全部非自有属性。注释兼容哨兵为直接写入的二进制 plist 原生注释属性，另有二进制测试属性；这不等于验证 Finder 注释框显示。
- 合成文件 chmod 0444 后的写失败、chmod 000 后的读失败、调用前删除后的失败；链接及越界路径拒绝。

JSONL 保存命令、真实退出码、输出与检查结果。`passed` 是探针检查，不是 Dan 的任务验收。`summary` 中的未验证项必须保留，不能用 16 KiB 样本推断容量上限，或用进程重开代替系统重启。

## 探针协议

属性名为 `com.findernotes.note.v1`；值是原始 UTF-8，无 JSON 包装、无第二份正式笔记。`v1` 标识格式版本，命名仍需在产品阶段保持兼容。新笔记不与 Finder 原生注释互通，也不自动迁移旧注释。

```sh
probe="${TMPDIR:-/tmp}/findernotes-fn01-xattr-probe"
"$probe" prepare
fn01_root='/粘贴本次 prepare 的完整 root'
"$probe" read "$fn01_root" work/mixed.png missing
"$probe" write-verify "$fn01_root" work/mixed.png mixed
"$probe" read "$fn01_root" work/mixed.png mixed
"$probe" write-verify "$fn01_root" work/mixed.png empty
"$probe" clear-verify "$fn01_root" work/mixed.png
"$probe" read "$fn01_root" work/mixed.png missing
```

`read` 可省略期望样本，只报告实际值的状态、长度和哈希；`sample NAME` 输出原始样本文本。`empty` 写入存在但长为零的属性；`clear-verify` 删除自有属性。这是存储语义验证，不预先决定产品清空按钮的交互。

成功为 stdout JSON 和退出 0；失败为 stderr JSON 与非零退出，系统失败保留 errno。写入成功必须正文回读、媒体内容与其他属性核对通过。耗时字段是单次系统调用和回读的耗时；JSONL 另记录进程命令总耗时，两者都不代表正式应用输入响应。

探针仅接受根内 `work/FILE` 或 `moved/FILE` 的合成 PNG/MOV；以目录 fd、`O_NOFOLLOW` 和文件 fd 操作，拒绝符号/硬链接及与种子内容不同的文件，操作后复核路径身份。该保护不替代产品中的编辑基线、冲突处理或竞态验收。

## Finder 界面步骤

自动矩阵只准备文件，不模拟这些 Finder 操作。根路径须取自本轮日志的 `finder-ready`：

1. Finder 按 ⌘⇧G 打开 `<ROOT>/work`。将 `finder-image.png` 改名为 `renamed-image.png`，将 `finder-video.mov` 改名为 `renamed-video.mov`。
2. 选中两文件，⌘C；打开 `<ROOT>/moved`，按 ⌥⌘V 移动。
3. 在 `moved` 选中这两个文件，⌘D 制作副本；把副本分别命名为 `copy-image.png`、`copy-video.mov`，保留 renamed 原件。不要按扩展名猜文件种类。
4. 记录实际操作者、步骤和异常，再运行：

```sh
fn01_root='/粘贴本轮 run-xattr.py 日志 finder-ready 的完整 root'
python3 validation/fn01/verify-finder-xattr.py "$fn01_root" > /tmp/fn01-xattr-finder.jsonl
```

此命令先核对两类原件身份不变、副本身份不同、笔记字节和媒体/已有属性；全部核对后才把副本写成 `cjk2000`，确认原件仍为 `mixed`。它只证明最终状态，须配合实际 Finder 操作记录，不能单靠文件已存在就认定 UI 测试通过。它是一次性检查；运行后副本正文已变化，再次执行前应建立新一轮样本，不要静默重置证据。

若要独立观察每个步骤，改名后、移动后和复制后分别执行 `read ROOT RELATIVE mixed` 并记录身份/哈希。三步合并完成后才回读时，明确注明没有中间采样。

Finder 控制通道或系统权限异常时，保留错误并由 Dan 操作；不要用命令行移动替代 Finder UI 的通过结论。只清理当前实验自己创建的临时根；验收前保留它们便于复查。

## 证据

- [自定义 xattr 本机记录](../../docs/evidence/fn01/2026-09-24-xattr.md)
- [原 Finder 注释历史记录](../../docs/evidence/fn01/2026-09-24.md)

跨卷、外置/网络卷、iCloud、压缩与转发、系统重启、正式签名/沙盒应用权限、保存期间同名替换等，必须有各自实测才能宣称支持。FN-02 与 M1 未由本探针启动。
