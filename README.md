# FinderNotes

FinderNotes 计划为 Finder 中的单份图片或视频提供原生笔记编辑入口，文件仍由 Finder 管理。按已确认的 D-006，正式笔记拟保存为文件上的自定义 xattr；不与 Finder 原生注释同步，不自动迁移旧注释。当前仓库包含 M0 验证探针与证据，尚无正式应用。

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

若 Xcode 安装在别处，先设置 `FINDERNOTES_DEVELOPER_DIR` 为该 `.app` 内的 `Contents/Developer`。实际工具链版本、签名和应用权限在 M0 记录。下述探针构建与隔离测试不代替正式 `.app`、系统服务或应用身份下的权限验收。

安装完成后运行 `./scripts/verify_toolchain.sh`。脚本仅在系统临时目录编译一个导入 AppKit 的最小程序，并在退出时清理；成功运行后才把工具链记为已验证。

## FN-01 验证入口

- [build-xattr.sh](validation/fn01/build-xattr.sh)：构建自定义 xattr 最小探针。
- [run-xattr.py](validation/fn01/run-xattr.py)：运行合成样本的隔离验证；运行方法及 Finder 人工步骤见[探针说明](validation/fn01/README.md)。
- [证据目录](docs/evidence/fn01/)：保存实际环境、命令、结果与未验证项。旧 Finder 原生注释实验保留为历史证据，不作为自定义 xattr 的通过结论。

在仓库根目录执行：

```sh
./validation/fn01/build-xattr.sh
python3 validation/fn01/run-xattr.py
```

每次运行新建独立临时目录并输出 JSONL 结果；Finder 界面操作按探针说明单独执行和记录。自定义探针路径可通过 `run-xattr.py --probe /absolute/path` 指定。

探针使用自有属性 `com.findernotes.note.v1` 保存原始 UTF-8 正文，验证文本完整性、持久化、文件操作后的保留情况及原件保护。路线选择不等于验证通过；当前结果以 FN-01 任务卡与对应证据为准。FN-02 的系统服务与权限验证另行开展，不由存储探针代替。

## 验证与协作

[M0 验证方案](docs/M0_VALIDATION.md)规定隔离样本和证据格式。仅在独立临时目录对测试副本写入；旧 Orbit 的服务、数据库与真实素材库不作为测试对象。

一个已授权的任务使用一个分支与 PR；PR 写明对应 Notion 任务、实际执行的检查、失败与未验证项及 Dan 的验收步骤。`Review` 表示待验收，只有 Dan 明确确认后才能将任务设为 `Done`。首次 PR 模板位于 [.github/pull_request_template.md](.github/pull_request_template.md)。
