# FinderNotes

FinderNotes 为 Finder 中的单份图片或视频提供原生笔记编辑入口，文件仍由 Finder 管理。仓库包含 FN-04 AppKit 应用工程，以及独立保留的 M0 验证探针与历史证据。FN-04 按 D-006 读取自定义 xattr `com.findernotes.note.v1`，编辑内容仅作为本次运行的内存草稿；不与 Finder 原生注释同步，不自动迁移旧注释。

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

## FN-04 应用入口

在仓库根目录执行：

```sh
./scripts/build_app.sh
./scripts/test_app.sh
```

`build_app.sh` 默认构建 **Release** 并核对代码签名，产物为 `.build/DerivedData/Build/Products/Release/FinderNotes.app`；它不自动安装应用。`test_app.sh` 使用 **Debug** 运行 XCTest，结果包位于 `.build/TestResults/`。也可在 Xcode 打开 [FinderNotes.xcodeproj](FinderNotes.xcodeproj)，选择 FinderNotes scheme。开发时可用 `FINDERNOTES_CONFIGURATION=Debug ./scripts/build_app.sh` 显式选择 Debug；真实 Finder 服务验收使用 Release，避免测试宿主影响服务派发。

本轮环境为 Xcode 27、macOS 26.6.2、arm64 和内置 APFS。工程的 deployment target 为 macOS 26.0，这只是构建最低版本设置，不表示 26.0 或所有后续版本均已实测。应用使用稳定 bundle ID `com.findernotes.FinderNotes`，当前为非沙盒、ad hoc 本机签名，未公证；不代表可分发版本。

脚本产物可直接用于本机验收。用户如需固定安装位置，可将指定的 Release `.app` 复制到自己选择的目录，例如 `~/Applications/`；先检查目标，不覆盖已有同名应用，也不要同时运行同 bundle ID 的多个构建。

使用 [FN-04 独立样本](validation/fn04/README.md)进行验收。在 Finder 单选一个本地普通图片或视频，再通过 **访达 → 服务 → FinderNotes 编辑笔记** 打开窗口。服务只使用本次传入的文件 URL，不跟随后续 Finder 选区；多选、目录、符号链接、硬链接和 Finder 替身会被拒绝。快捷键由用户在系统设置的键盘服务快捷键中自行配置，应用不会自动设置。

窗口提供只读可复制的文件名和路径，以及支持纯文本粘贴、系统查找、撤销重做的正文编辑区。相同路径和文件身份的重复调用复用当前窗口与草稿；已有空笔记、属性不存在及读取失败分别显示。**保存按钮和 Command-S 均不可用**。有草稿改动时，切换文件、关闭窗口或退出共用确认流程，默认“继续编辑”；“复制草稿”后仍保留当前会话，只有明确选择“丢弃并切换／关闭／退出”才离开。读取新文件失败时保留原目标和草稿。

FN-04 不写入媒体或笔记属性，不提供 Markdown 导出、预览、自动保存或持久恢复。需要保留的文字应在离开前复制；异常退出不能恢复内存草稿。应用不默认要求自动化、辅助功能或完全磁盘访问权限，不修改 TCC 设置。受保护目录、云盘、NAS、外置卷及正式签名／沙盒行为没有由本机合成副本验证代替。

实际执行结果、失败与 Dan 的验收步骤见 [FN-04 交付证据](docs/evidence/fn04/2026-09-24.md)。真实中文输入法的组合态操作仍待 Dan 验收；注入中文字符串不能替代真实输入法操作。本轮截图捕获失败，没有有效截图作为界面证据。

### 同 bundle ID 的服务缓存处理

Debug 测试宿主及本任务的 VisualDerivedData 构建也使用 `com.findernotes.FinderNotes`。运行测试后，macOS 可能把服务指向这些构建。若需要恢复 Release 的本机服务验收，先正常退出本任务的 FinderNotes 实例并处理草稿，再从仓库根目录仅注销以下两个确认为本任务生成的构建，最后注册 Release：

```sh
FN04_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$FN04_LSREGISTER" -u "$PWD/.build/DerivedData/Build/Products/Debug/FinderNotes.app"
"$FN04_LSREGISTER" -u "$PWD/.build/VisualDerivedData/Build/Products/Debug/FinderNotes.app"
"$FN04_LSREGISTER" -f "$PWD/.build/DerivedData/Build/Products/Release/FinderNotes.app"
```

这是对指定 `.app` 的注册维护，不删除应用。只处理本任务的路径；不要使用 LaunchServices 全局重建／重置命令，不强制重启 Finder，不修改系统权限。注册成功也不代表 Finder 已派发到正确应用，仍需按交付证据进行真实服务调用核对。

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
