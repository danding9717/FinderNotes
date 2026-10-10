# FN-11 人工验收记录

日期：2026-10-10。任务：[FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。

Dan 打开最新验收构建、试用“源码模式 / 实时阅览”后明确回复：

> 验收通过，完成后续标准收尾工作。

## 验收对象

基线为 `235b13f26b640e063c113ce40b30eae72f498ae4`，实现分支为 `codex/fn-11-markdown-layout`。接受当前 FN-11 完整交付：原地 Markdown 排版、输入期间局部更新与组合输入保护、普通列表和任务列表回车续写、可点击任务复选框，以及底部“源码模式 / 实时阅览”菜单。

实际交付应用为 `.build/FN11TaskReview/Build/Products/Release/FinderNotes.app`，身份 `com.findernotes.FinderNotes.FN11TaskReview`。应用可执行文件 SHA-256：

```text
12f36cafd8bf348b5aee0a5e015b2454c8abd3a90efed109b3a7177ad9e6cf3f
```

收尾前，将当前源码、依赖、组件测试及应用与验收阶段的指纹合并核对，31 项全部一致；未因收尾修改生产代码。可追溯指纹见 `accepted-source-sha256.txt`。此前 2155 项组件断言通过的原始结果保存于 `verification-result.txt`；收尾没有重复运行未变化的功能套件，另行复核严格 codesign 与 `git diff --check` 均通过。

具体实现、命令、真实 UI 观察及历史失败分别见 [MODE_MENU.md](MODE_MENU.md)、[TASK_LIST.md](TASK_LIST.md)、[LIST_CONTINUATION.md](LIST_CONTINUATION.md)、[STABILITY.md](STABILITY.md) 与 [VALIDATION.md](VALIDATION.md)。旧阶段的“未提交”“待验收”描述保留为当时记录，当前人工验收事实以本页及 Notion 最新记录为准。

## 证据边界

本次明确接受当前交付，不追加或推定新的测试结果。真实中文候选、长期滚动、Finder/TCC、Intel 运行及安装版等历史未验证边界保留；未关闭或覆盖用户正在试用的应用与草稿，也未启动其他任务。

Git 提交、PR 与合并结果在 Notion 中分别回写。此前明确排除合并，本轮在准备好具体 PR 后再确认合入 main；人工验收事实不因 Git 收尾尚未完成而回退。
