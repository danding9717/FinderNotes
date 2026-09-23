# FinderNotes

FinderNotes 计划为 Finder 中的单份图片或视频提供原生笔记编辑入口。文件仍由 Finder 管理。当前仓库保存项目约定与设计说明；Finder 注释存储、系统服务入口和应用行为均待 M0 本机验证。

## 项目入口

- [项目首页 · PRO-FinderNotes](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)
- [设计与决策](https://app.notion.com/p/3e4e7607d6498101ae7cede78291e918)
- [开发与验收约定](https://app.notion.com/p/3e4e7607d6498155b515fd03212b3437)

需求、任务状态与验收结论以 Notion 的当前记录为准。开发前先阅读 [AGENTS.md](AGENTS.md)、本轮任务卡和实际 Git 状态。初始技术方案保存在 [设计说明](Finder_Notes_Codex_Design.md)；其中的候选路线尚不代表实测结论。

## 本机准备

目标工具链是与当前 macOS 兼容的 Xcode 27 正式版，安装前核对 [Apple 官方兼容要求](https://developer.apple.com/xcode/system-requirements)。只安装 Command Line Tools 不足以验证完整 `.app`、Finder 服务和应用权限。Xcode 安装、许可和首次启动完成后，在项目命令中指定其开发目录，不切换系统全局设置：

```sh
export DEVELOPER_DIR="${FINDERNOTES_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
swift --version
```

若 Xcode 安装在别处，先设置 `FINDERNOTES_DEVELOPER_DIR` 为该 `.app` 内的 `Contents/Developer`。实际工具链版本、签名和应用权限在 M0 记录。仓库尚无应用工程、应用构建命令或自动化测试；建立最小验证工程后再补入实测可复现的命令。

安装完成后运行 `./scripts/verify_toolchain.sh`。脚本仅在系统临时目录编译一个导入 AppKit 的最小程序，并在退出时清理；成功运行后才把工具链记为已验证。

## 验证与协作

[M0 验证方案](docs/M0_VALIDATION.md)规定隔离样本和证据格式。仅在独立临时目录对测试副本写入；旧 Orbit 的服务、数据库与真实素材库不作为测试对象。

一个已授权的任务使用一个分支与 PR；PR 写明对应 Notion 任务、实际执行的检查、失败与未验证项及 Dan 的验收步骤。`Review` 表示待验收，只有 Dan 明确确认后才能将任务设为 `Done`。首次 PR 模板位于 [.github/pull_request_template.md](.github/pull_request_template.md)。
