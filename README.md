# FinderNotes

FinderNotes 为 Finder 中的单份图片或视频提供原生笔记编辑入口，文件仍由 Finder 管理。FN-05 在 FN-04 AppKit 窗口上加入手动保存和 Markdown 快照导出。正式笔记只写自有 xattr `com.findernotes.note.v1` 的原始 UTF-8 正文；不与 Finder 原生注释同步，不自动迁移旧注释。M0 探针与历史证据独立保留。

## 项目入口

- [项目首页 · PRO-FinderNotes](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)
- [设计与决策](https://app.notion.com/p/3e4e7607d6498101ae7cede78291e918)
- [开发与验收约定](https://app.notion.com/p/3e4e7607d6498155b515fd03212b3437)

需求、任务状态与验收结论以 Notion 的当前记录为准。开发前先阅读 [AGENTS.md](AGENTS.md)、本轮任务卡和实际 Git 状态。[初始设计说明](Finder_Notes_Codex_Design.md)作为历史归档保留，其中的 Finder 原生注释路线已由 D-006 替代。

## 本机准备

目标工具链是与当前 macOS 兼容的 Xcode 27 正式版，安装前核对 [Apple 官方兼容要求](https://developer.apple.com/xcode/system-requirements)。只安装 Command Line Tools 不足以验证完整 `.app`、Finder 服务和应用权限。Xcode 安装、许可和首次启动完成后，在项目命令中指定其开发目录，不切换系统全局设置：

```sh
export DEVELOPER_DIR="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
swift --version
```

若 Xcode 安装在别处，先设置 `FINDERNOTES_DEVELOPER_DIR` 为该 `.app` 内的 `Contents/Developer`。各阶段的实际工具链、签名和权限结果分别保存在对应证据中。下述探针构建与隔离测试不代替产品 `.app`、系统服务或应用身份下的权限验收。

安装完成后运行 `./scripts/verify_toolchain.sh`。脚本仅在系统临时目录编译一个导入 AppKit 的最小程序，并在退出时清理；成功运行后才把工具链记为已验证。

## FN-05 隔离验收应用

在仓库根目录执行：

```sh
FINDERNOTES_BUILD_PROFILE=fn05 ./scripts/build_app.sh
FINDERNOTES_BUILD_PROFILE=fn05 ./scripts/test_app.sh
```

`build_app.sh` 构建 Release 并核对代码签名，产物为 `.build/DerivedData/Build/Products/Release/FinderNotes.app`；`test_app.sh` 构建独立 Debug 测试宿主，结果包在 `.build/TestResults/`。`fn05` profile 的 Release 身份为 `com.findernotes.FinderNotes.FN05Validation`，服务菜单为“FinderNotes FN05 验收编辑笔记”；Debug 身份为 `.FN05Tests`，不声明服务。`m1fix` profile 为本轮界面与生命周期回归验收使用独立的 `com.findernotes.FinderNotes.M1FixValidation` Release 身份、`com.findernotes.FinderNotes.M1FixTests` Debug 身份；服务只由 Release 提供，菜单为“FinderNotes M1 修正验收编辑笔记”。脚本不安装应用，但 Xcode 构建会注册产物；保留 FN-04/FN-05 验收应用及原服务，正式应用身份的服务派发仍待单独验证。

本轮环境为 Xcode 27、macOS 26.6.2、arm64 和内置 APFS。工程的 deployment target 为 macOS 26.0，只是构建设置，不表示该版本已实测。隔离验收构建为非沙盒、ad hoc 本机签名，未公证；不代表可分发版本。

使用 [FN-05 新建的独立样本](validation/fn05/README.md)验收。先记录 `prepare.py` 输出的临时目录，在 Finder 单选其中一张图片或一段视频，再经 **访达 → 服务 → FinderNotes FN05 验收编辑笔记** 打开。服务使用本次文件 URL，固定目标；多选、目录、符号链接、硬链接及 Finder 替身按已有规则拒绝。

窗口保留文件名、路径的只读显示及原生纯文本编辑、查找和撤销重做。保存按钮与 Command-S 共用手动保存：写前核对当前文件身份及自有属性基线，写后完整回读原始字节并复核身份，成功才显示已保存。无正文的首次显式保存创建零字节属性；将已有正文删空后保存也保留零字节属性，以区别“尚无笔记”。已知外部修改、文件消失或被替换时停止覆盖并保留草稿。检查与写入不是原子操作，不能据此承诺任意并发安全；整理或移动文件前请结束编辑。

“导出 Markdown…”把点击时的草稿存为独立 UTF-8 快照，默认文件名为完整原文件名加 `.note.md`，例如 `photo.PNG.note.md`。导出不改变笔记保存状态；目标必须是新文件，重名时改名或换目录，应用不会执行覆盖。写入失败或结果未能确认时，草稿仍可复制、导出。有未保存内容或保存错误时，切换、关闭、退出会提醒先完成输入并保存；默认返回编辑器，只有明确丢弃才离开。编辑器的“复制草稿”按钮仍可使用，复制本身不会离开。保存及导出期间仍可编辑、复制，但暂缓切换、关闭、退出；中文输入组合期间请先完成输入再保存或导出。

本轮没有预览、自动保存或异常退出草稿恢复。应用不默认要求自动化、辅助功能或完全磁盘访问权限，不修改 TCC。受保护目录、云盘、NAS、外置卷、正式身份及分发行为未由临时副本验证代替。

实际测试、限制和 Dan 的图片／视频往返步骤见 [FN-05 交付证据](docs/evidence/fn05/2026-09-25.md)。FN-04 的真实中文输入法、完整缩放和外观、有效截图等未验证项继续保留于 [FN-04 报告](docs/evidence/fn04/2026-09-24.md)。

## M1 界面与生命周期回归验收应用

使用独立的 M1 修正 profile 构建，避免覆盖历史验收身份：

```sh
FINDERNOTES_BUILD_PROFILE=m1fix ./scripts/build_app.sh
FINDERNOTES_BUILD_PROFILE=m1fix ./scripts/test_app.sh
```

从 Finder 选择临时样本，运行 **访达 → 服务 → FinderNotes M1 修正验收编辑笔记**。关闭最后一个已确认可丢弃的窗口后，应用退出；之后再从同一服务打开下一样本，记录进程 PID 和 Dock 状态。该隔离验收身份及服务只用于本地 M1 回归验证。

## FN-01 历史验证入口

- [build-xattr.sh](validation/fn01/build-xattr.sh)：构建自定义 xattr 最小探针。
- [run-xattr.py](validation/fn01/run-xattr.py)：运行合成样本的隔离验证；运行方法及 Finder 人工步骤见[探针说明](validation/fn01/README.md)。
- [证据目录](docs/evidence/fn01/)：保存实际环境、命令、结果与未验证项。旧 Finder 原生注释实验保留为历史证据，不作为自定义 xattr 的通过结论。

在仓库根目录执行：

```sh
./validation/fn01/build-xattr.sh
python3 validation/fn01/run-xattr.py
```

每次运行新建独立临时目录并输出 JSONL 结果；Finder 界面操作按探针说明单独执行和记录。自定义探针路径可通过 `run-xattr.py --probe /absolute/path` 指定。

探针使用自有属性 `com.findernotes.note.v1` 保存原始 UTF-8 正文，验证文本完整性、持久化、文件操作后的保留情况及原件保护。路线选择不等于验证通过；结果以 FN-01 任务卡与对应证据为准。FN-02 的系统服务与权限验证有独立记录，不由存储探针代替。

## 验证与协作

[M0 验证方案](docs/M0_VALIDATION.md)规定隔离样本和证据格式。仅在独立临时目录对测试副本写入；旧 Orbit 的服务、数据库与真实素材库不作为测试对象。

一个已授权的任务使用一个分支与 PR；PR 写明对应 Notion 任务、实际执行的检查、失败与未验证项及 Dan 的验收步骤。`Review` 表示待验收，只有 Dan 明确确认后才能将任务设为 `Done`。首次 PR 模板位于 [.github/pull_request_template.md](.github/pull_request_template.md)。

## FN-02 历史验证入口

原生 AppKit 系统服务验证应用、独立合成样本与构建／验收方法见 [validation/fn02](validation/fn02/README.md)，本机结果见 [FN-02 实测证据](docs/evidence/fn02/2026-09-24.md)。仅为 M0 验证，不代表 M1 产品或正式权限配置已交付。
