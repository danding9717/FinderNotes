# FN-10 窗口置顶验证记录

日期：2026-10-10。任务：[FN-10](https://app.notion.com/p/3f5e7607d6498173b8b2e77625e8a824)。

## 验证对象与环境

- 工作树：`/Users/danding/.codex/worktrees/fn-10-window-pin/FinderNotes`；分支 `codex/fn-10-window-pin`；基线 `936dc875a04fd569ac35dec5b0b21b5bacb4ce8a`。
- 产品变更仅 `EditorWindowController.swift` 和 `AppDelegate.swift`，40 行新增。顶部按钮和窗口菜单共用内存状态，切换 floating/normal；显式 managed/participatesInCycle，避免浮动层级的默认 transient 行为。不持久化选择。
- macOS 26.7.1（25G241），Apple M2 / arm64；Xcode 27.0、Swift 6.4，`/Applications/Xcode.app/Contents/Developer`。
- 源文件 SHA-256：`AppDelegate.swift` = `9d39fe845fe5000270df3361c10622617a215723d87e4a062d2a46abdfce3b69`；`EditorWindowController.swift` = `653681e062c5c7b2eaf171ebcb1cb8b113aed26c4d75ea6dbd79a0c03cc25395`。

## 构建与组件检查

在上述工作树执行：

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN10" ./scripts/build_app.sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN10Review" ./scripts/build_app.sh FINDERNOTES_APP_SUFFIX=.FN10Review INFOPLIST_FILE="$PWD/.build/FN10Review-Info.plist"
zsh .build/FN10Smoke/run.sh
git diff --check
```

两个 Release 构建及脚本内严格 codesign 检查均通过。只有 AppIntents 元数据跳过警告（项目未依赖该框架）。标准构建日志保留于 `.build/FN10-build.log`，隔离身份构建日志为 `.build/FN10Review-build.log`。

临时组件 harness：**33 passed / 0 failed**，日志 `.build/FN10Smoke/smoke.log`，源码及命令保留于同目录。它编译原产品 Swift 源（替换 main 入口），使用 `-Xfrontend -disable-access-control -whole-module-optimization` 注入不使用恢复存储的 controller。窗口全程隐藏，未注册服务或访问默认恢复目录。

覆盖按钮 performClick、菜单 action/validation、层级与桌面管理 flags、controller 复用与新实例关闭；文本、选区、firstResponder、draftRevision、dirty/status、撤销重做、程序化 marked text 均保留。受控阻塞 NoteWriter 期间切换置顶，释放后真实 xattr 回读与完整 UTF-8 草稿一致；同 controller 安装第二份合成 PNG 后保留选择。

组件切文件检查走 session install/render，未调用会显示窗口的 receive。注入 controller 的检查未执行 AppDelegate factory 的即时菜单回调。程序化 marked text 不代表真实输入法候选验收。

## 真实界面检查

通过 CUA 操作独立构建，身份 `com.findernotes.FinderNotes.FN10Review`，版本 **0.1.0（1）**，显示名 **FinderNotes FN10 Review**。这是开发验证产物，不是 V1.0 发布版；没有覆盖 `~/Applications/FinderNotes.app`。临时 Info 只改独立身份/显示名和测试服务标签、端口（`FN10 测试置顶（隔离副本）` / `FinderNotesFN10Review`），产品源相同。

已观察：

- 启动顶部按钮为 off；按钮可变为 on，窗口菜单 action 可使顶部按钮恢复 off。
- Finder 中通过独立测试服务打开 `.build/FN10Fixtures/pin-a.png`；输入中文及 emoji（粘贴），选择 `中文与 emoji 🙂` 后点击置顶，选区仍在；紧接着键盘 Right、X 插入正确位置，编辑器保持焦点。
- 撤销删除 X，重做恢复 X；置顶开启时打开并完成 Markdown 导出面板，返回编辑器，状态显示已保存和已导出。
- 从 Finder 服务切换到第二份合成图片 `pin-b.png`，置顶仍为 on。
- 退出后用进程查询确认原进程结束，再启动同一测试应用，按钮为 off。
- 拖至最小窗口 **500×360 pt**；空窗口与加载 `pin-b.png` 后的截图均显示顶部按钮、编辑区、底部操作、状态及长路径正常排列。长错误消息尚未验证。

独立 `/usr/bin/xattr -px com.findernotes.note.v1` 读取 `pin-a.png` 并与导出文件比较，两者均为下列 **52 字节 UTF-8**，SHA-256 `c37543f3f504e84418edc029c3f016632825b2b5841c1e6f314198ceeccf6f0c`：

```text
FN-10 测试：中文与 emoji 🙂X
# 原文保留
```

末尾保留换行。合成图片及导出仅位于本次 `.build/FN10Fixtures`；组件临时 PNG 已由 harness 清理。UI 测试结束时测试应用已退出。

## 失败与未验证边界

- 初次临时 harness 未启用 whole-module-optimization，跨文件私有函数链接失败；加该编译选项后通过。原失败日志 `.build/FN10Smoke/attempt-1-link.log` 保留。这是 harness 配置失败。
- 首次独立 Python 读取使用 `os.getxattr`，本机该解释器未提供；改用系统 xattr 十六进制读取后完成上述字节比较。这是读取工具失败。
- CUA 菜单截图不可用，AX 树未报告菜单勾选值；菜单勾选同步目前有组件检查和代码证据，仍需人工核对实际勾选。
- 点击最小化后 UI 工具未返回可确认的最小化状态；没有将该尝试记为通过。最小化/恢复仍待人工验证。
- 跨普通应用实际遮挡顺序、取消置顶后的顺序、Spaces/全屏不跟随、真实中文输入法候选、关闭保护与置顶组合、长错误消息及已安装 LocalTrial 身份未复验。未验证项不推定通过，历史 FN08-I07/I08 保留。

## Dan 验收步骤

1. 打开 `.build/FN10Review/Build/Products/Release/FinderNotes.app`；在 Finder 选择本次合成 PNG，通过独立测试服务打开，确认顶部与“窗口 → 置顶”勾选双向同步。
2. 让其他普通应用窗口与笔记窗口重叠；开启、取消置顶并检查遮挡顺序。切换桌面及其他应用的全屏桌面，确认笔记不跟随，返回后选择保留。
3. 验证最小化/恢复、导出保存面板及有改动时的关闭保护；在真实中文输入法候选、鼠标/键盘选区、保存和撤销重做期间切换置顶。
4. 同次运行切换第二份测试图片确认选择保留；退出重启确认关闭。保存、重新读取及导出比较完整原文。

测试应用保留独立服务身份以便验收；构建产物、临时 harness 和合成文件在 `.build` 下被 Git 忽略，后续清理/归档前需保留必要证据。正式任务状态与人工验收仅维护在 Notion。
