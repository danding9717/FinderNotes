# FinderNotes

FinderNotes 为 Finder 中的单份图片或视频提供原生笔记编辑入口，文件仍由 Finder 管理。正式笔记只写自有 xattr `com.findernotes.note.v1` 的原始 UTF-8 正文；不与 Finder 原生注释同步，不自动迁移旧注释。

## 个人版本与历史交付

个人版本沿用身份 `com.findernotes.FinderNotes.LocalTrial`，安装位置 `~/Applications/FinderNotes.app`，Finder 服务为“用 FinderNotes 编辑笔记”。`0.1.2（13）` 已发布；本轮准备单仓更新源迁移，实际安装版本请在应用中查看。历史 v0.1 交付版本为 `0.1.0（11）`。[安装、使用、恢复与卸载手册](docs/LOCAL_TRIAL.md)说明功能、构建方式和限制。

Dan 于 2026-09-27 明确确认 FinderNotes v0.1、M2 和项目整体交付通过。整体验收不改变已有失败、未验证项或 FN08-I07／FN08-I08 的结论；项目状态与清理结果以 [Notion 项目首页](https://app.notion.com/p/3e4e7607d6498038adeee4c1069f2bb9)当前记录为准。该次历史交付为个人本机使用，未公开发布。

历史 v0.1 交付后的本地清理移除当时的测试代码、测试 target/profile、合成样本和本地历史验收证据。Git 历史与 Notion 记录保留；清理不代表历史问题已修复，也不构成当前构建的新一轮功能验收。

## 手动更新与单仓迁移

`0.1.1（12）` 加入 **FinderNotes → 检查更新…**，已于 2026-10-10 覆盖个人安装件并获 Dan 验收。旧版 11 没有更新器，首次须显式安装一次；后续通过应用内更新。验收、Git 整合与发布分别记录，验收不代表 V1.0 整体交付。

[FN-13 单仓迁移](https://app.notion.com/p/3f5e7607d64981659145f36b04d7b241) 按 Dan 授权公开源码，将源码、更新列表和安装包统一到 [`danding9717/FinderNotes`](https://github.com/danding9717/FinderNotes)。新更新列表由 `updates` 分支提供：

```text
https://raw.githubusercontent.com/danding9717/FinderNotes/updates/appcast.xml
```

迁移安排为 **0.1.2（13）→ 0.1.3（14）→ 0.1.4（15）**：旧源只提供桥接版 14，14 内嵌新源；再由新源提供 15，以验证升级后仍能检查、下载安装并重启。14 和 15 使用同一迁移实现，仅版本及说明不同。这是待实测的迁移路径；只有 Dan 完成升级并确认新源检查、安装正常后，才删除 `FinderNotes-updates`。

Release 附件只保留安装包 ZIP 和 `SHA256SUMS`；更新说明内嵌于更新列表，开发材料归档至 `docs/releases/`。GitHub 自动生成的源码 ZIP 和 tar.gz 仍会显示。操作与失败处理见[更新手册](docs/UPDATES.md)，历史测试和保留边界见[FN-12 验证报告](docs/FN12_VALIDATION.md)。

## 构建个人版本

需要与当前 macOS 兼容的完整 Xcode；工具链配置可用 `./scripts/verify_toolchain.sh` 查看。如 Xcode 位于其他位置，为当前命令设置 `FINDERNOTES_DEVELOPER_DIR`，不切换系统全局开发目录。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-release" \
  FINDERNOTES_BUILD_PROFILE=local-trial ./scripts/build_app.sh
```

`local-trial` 只接受 Release；脚本检查签名、bundle ID、版本、名称及服务配置，输出 `.build/DerivedData-release/Build/Products/Release/FinderNotes.app`。构建不安装或覆盖当前应用。保留的 `standard` profile 使用工程基础身份，与真实安装件不同，默认关闭更新；构建个人版请明确使用 `local-trial`。版本以当前提交中的 `FinderNotes/Info-LocalTrial.plist` 为准；复现某次发布请使用该发布对应的固定提交。

应用图标的正式资源位于 `FinderNotes/Assets.xcassets`；`scripts/prepare_app_icon.sh` 从 `design/app-icon/FinderNotes-fullbleed.png` 重建图标尺寸。保留的旧设计源与说明见 [图标设计记录](design/app-icon/README.md)。安装脚本 `scripts/install_local_trial.py` 默认拒绝覆盖已有目标；显式升级入口与签名校验、失败现场处理见[更新手册](docs/UPDATES.md)，不会因构建或准备材料自动安装。

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

后续工作先阅读 [AGENTS.md](AGENTS.md)、Notion 的当前授权范围和实际 Git 状态。[初始设计说明](Finder_Notes_Codex_Design.md)作为设计历史保留，其中的 Finder 原生注释路线已由 D-006 替代。本轮仅推进获授权的 FN-13 单仓更新源迁移，不启动其他任务。
