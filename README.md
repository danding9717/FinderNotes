# FinderNotes

FinderNotes 为 Finder 中的单份图片或视频提供原生笔记编辑入口，文件仍由 Finder 管理。正式笔记只写自有 xattr `com.findernotes.note.v1` 的原始 UTF-8 正文；不与 Finder 原生注释同步，不自动迁移旧注释。

## v0.1 本地交付

当前使用版为 `0.1.0 (11)`，身份 `com.findernotes.FinderNotes.LocalTrial`，安装位置 `~/Applications/FinderNotes.app`，Finder 服务为“用 FinderNotes 编辑笔记”。[安装、使用、恢复与卸载手册](docs/LOCAL_TRIAL.md)说明当前功能、构建方式和限制。

Dan 于 2026-09-27 明确确认 FinderNotes v0.1、M2 和项目整体交付通过。整体验收不改变已有失败、未验证项或 FN08-I07／FN08-I08 的结论；项目状态与清理结果以 [Notion 项目首页](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)当前记录为准。本次交付仍为个人本机使用，未公开发布。

交付后的本地清理移除测试代码、测试 target/profile、合成样本和本地历史验收证据。Git 历史与 Notion 记录保留；清理不代表历史问题已修复，也不构成当前构建的新一轮功能验收。

## 构建当前版本

需要与当前 macOS 兼容的完整 Xcode；工具链配置可用 `./scripts/verify_toolchain.sh` 查看。如 Xcode 位于其他位置，为当前命令设置 `FINDERNOTES_DEVELOPER_DIR`，不切换系统全局开发目录。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-build11" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh
```

`local-trial` 只接受 Release；脚本检查签名、bundle ID、版本、名称及服务配置，输出 `.build/DerivedData-build11/Build/Products/Release/FinderNotes.app`。构建不安装或覆盖当前应用。保留的 `standard` profile 使用工程基础身份，与当前安装件不同；重建当前使用版请明确使用 `local-trial`。

应用图标的正式资源位于 `FinderNotes/Assets.xcassets`；`scripts/prepare_app_icon.sh` 从 `design/app-icon/FinderNotes-fullbleed.png` 重建图标尺寸。保留的旧设计源与说明见 [图标设计记录](design/app-icon/README.md)。安装脚本 `scripts/install_local_trial.py` 拒绝覆盖任何已存在的目标，使用与卸载步骤见手册。

## 功能与数据边界

- 单份本地图片／视频的原生编辑、预览、手动保存和空闲自动保存；视频不自动播放，预览不可用时仍可编辑。
- Markdown 导出是独立快照，不覆盖已有目标，不与 xattr 双向同步；复制与导出保留编辑会话和恢复草稿。
- 保存只有在身份与完整正文回读确认后才显示成功。权限、身份或冲突失败会暂停自动保存；最后核对与写入之间仍不是原子 CAS。
- 关闭、切换、退出遇到未保存内容或错误时默认继续编辑；明确丢弃才离开。高级选项提供外部版本核对与已落盘草稿恢复。
- 恢复数据位于 `~/Library/Application Support/com.findernotes.FinderNotes.LocalTrial/DraftRecovery/v1/`，是本机明文未保存草稿，不是笔记历史库。卸载应用不默认删除恢复记录或媒体 xattr。
- 可用 `scripts/read_note.py` 独立读取或安全导出已保存的正式笔记；该工具从原验证目录迁出，读取与导出逻辑不变。

完整操作、权限说明和传输限制见[使用手册](docs/LOCAL_TRIAL.md)。本机 ad hoc 签名、非沙盒、未公证，deployment target 不代表所有 macOS、Intel、图片／视频格式或传输路径已经实测支持。

## 项目入口与历史记录

- [项目首页 · PRO-FinderNotes](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)
- [设计与决策](https://app.notion.com/p/3e4e7607d6498101ae7cede78291e918)
- [开发与验收约定](https://app.notion.com/p/3e4e7607d6498155b515fd03212b3437)
- [历史原始证据（固定 Git 提交）](https://github.com/danding9717/FinderNotes/tree/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence)
- [FN-08 验收记录与 I07／I08 保留结论](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/ACCEPTANCE.md)
- [FN-08 实测报告及失败／未验证项](https://github.com/danding9717/FinderNotes/blob/868a4160cdb10f234ad3ec3cf94f631bd7d80591/docs/evidence/fn08/2026-09-27.md)

后续工作先阅读 [AGENTS.md](AGENTS.md)、Notion 的当前授权范围和实际 Git 状态。[初始设计说明](Finder_Notes_Codex_Design.md)作为设计历史保留，其中的 Finder 原生注释路线已由 D-006 替代。本轮不启动下一版本。
