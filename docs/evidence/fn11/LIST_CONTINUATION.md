# FN-11 列表回车续写

> 后续任务列表交互补充见 [TASK_LIST.md](TASK_LIST.md)。下文保留对应阶段的历史结果，不代表新增任务交互的最终结论。

日期：2026-10-10。任务：[FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。Dan 反馈 `1.this is a test.` 换行后没有继续 `2.`，本轮按直接反馈补充这一窄范围。原输入稳定性修正及历史证据见 [STABILITY.md](STABILITY.md)，不启动其他任务。

## 实际行为

Markdown 开启时，普通 Return 支持续写：

```text
1.this is a test.
2.
```

- 有序列表 `1. text`、`9) text` 递增为 `2. `、`10) `；无空格的 `1.text` 也识别，保留旧行原文，下一项补至少一个空格。
- 无序列表 `-`、`+`、`*` 继续原标记。保留当前行缩进和标记后已有的空格／tab；保留 CRLF、LF 或 CR 换行样式。
- 空项末尾再次 Return，删除本行标记及分隔空白，保留缩进并退出列表，不新增一行。编号或标记内部的光标／选区使用普通原生换行。
- 正文中间 Return 分割当前项；允许经验证的单行正文选区替换。多段选区、多选区、代码围栏（含列表正文开启的围栏）、任务勾选框、分隔线及 Markdown 关闭时保留原生行为。
- 不接管输入法 marked text 状态下的 Return；粘贴和输入法 `insertText` 中的换行不触发列表补全。支持 1 至 9 位 ASCII 编号；达到 999999999 的非空项使用普通换行，避免生成超出 Markdown 语法范围的编号。不重编号后续项，不新增任务勾选框、引用续写或通用补全。

兼容无空格续写只作用于键盘行为，未扩展 Markdown 解析语法；需要作为标准有序列表排版时，使用 `1. this is a test.`。自动前缀是用户 Return 编辑的一部分，保存／复制／导出／恢复记录完整新原文；显示排版本身仍不改正文字符。

## 实现与代码状态

`CompositionTextView.insertNewline` 只在模式开启、可编辑、非 marked text、单选区时调用纯函数 `MarkdownListContinuation.plan`。规划器验证 UTF-16 范围和完整 Unicode scalar 边界，同步核对当前原文中的列表及围栏；返回一次替换。接入既有 `insertText(_:replacementRange:)`，前后断开撤销合并，沿原生 storage 通知、session revision、自动保存和恢复通路处理，不额外调用正文通知或直接替换 storage。

当前目录 `/Users/danding/Project/AI/FinderNotes`，分支 `codex/fn-11-markdown-layout`，基线 `235b13f26b640e063c113ce40b30eae72f498ae4`。保留此前未提交改动，本轮新增 helper、原生 Return 接入和检查；未提交、推送、合并或安装，无 PR。存储、依赖版本及其他任务不变。

## 验证结果

环境：macOS 26.7.1（25G241）、M2／arm64、Xcode 27.0（27A266a）、Swift 6.4。Release 构建 arm64／x86_64，运行只覆盖 arm64。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11" ./scripts/build_app.sh \
  FINDERNOTES_APP_SUFFIX=.FN11Review \
  INFOPLIST_FILE="$PWD/.build/FN11Review-Info.plist" \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages" \
  -disableAutomaticPackageResolution
FINDERNOTES_FN11_SKIP_BUILD=1 FINDERNOTES_CONFIGURATION=Release scripts/verify_fn11.sh
codesign --verify --deep --strict --verbose=2 .build/FN11/Build/Products/Release/FinderNotes.app
git diff --check
```

最终构建、严格签名验证及 diff 检查通过。组件整套通过 **1890 条断言**：原有 1180 条稳定性／存储／排版回归、101 条纯续写规划检查、609 条原生 Return／保存集成检查。

22 个原生场景通过 `doCommand(by: #selector(NSTextView.insertNewline(_:)))` 触发，检查精确原文、光标、一次字符事务、单步撤销／重做，以及即时和解析完成后远段字体、标记、列表／引用装饰。模拟 marked text 与禁用续写的同源原生行为对照，未插入额外编号。实际隐藏 EditorWindowController 验证自动前缀使 revision 恰好增加一次，既有自动保存正式写入临时 PNG 的 xattr 并回读确认；撤销／重做继续捕获完整草稿，媒体字节不变。纯规划覆盖 CRLF、emoji、组合字符、范围无效、编号上限、围栏和空项等边界。

审查中发现两处边界问题并修正：列表正文开启的围栏未被原扫描保护；空项编号内部光标可能误删整项。新增相应检查后，最终整套通过。预修正的 1795 条快照不作为最终结论。

日志：`.build/FN11Evidence/list-build-final.log`、`.build/FN11Evidence/list-final-verification/{compile,result}.log`；共享 `.build/FN11Verification/` 同时保留当前日志及组件位图。SHA-256 清单：`.build/FN11Evidence/list-sha256.txt`。组件临时文件、空测试偏好域、运行锁和测试进程已清理，不清理本轮 UI 证据。

## 评审应用与真实 UI 边界

发现已有 FN11Review 正在编辑用户实际文件后，未对该编辑器执行输入、保存、退出或重启操作。另将最终构建复制到 `.build/FN11ListReview/FinderNotes.app`，仅修改评审副本的 bundle 显示名、标识和服务名并重新 ad hoc 签名、严格验证。独立身份 `com.findernotes.FinderNotes.FN11ListReview`，服务“FN11 列表续写测试（隔离副本）”，偏好及恢复目录与正在使用的应用分离；这不是安装或覆盖 LocalTrial。

该独立应用已实际启动，空窗口及 Markdown 开启状态正常。用新 Finder 窗口导航并选中了本轮合成 PNG，但打开服务菜单时工具报告 Finder 状态改变；重新绑定后确认已切换到桌面，停止继续操作。未完成最终应用的服务加载／真实 Return 检查，不将程序化命令检查称为真实按键或中文输入法通过。

评审应用：`/Users/danding/Project/AI/FinderNotes/.build/FN11ListReview/FinderNotes.app`。合成副本：`/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/FinderNotes-FN11-ListUI-vktw1juh/list-test.png`，同目录 `original.md` 保留原文。未写入真实素材或操作其他任务。

## Dan 的验收

1. 使用独立列表评审应用及上述合成副本，确认窗口路径和服务身份。输入 `1.this is a test.` 后 Return，下一行出现 `2. `；继续输入并 Return 得到 `3. `，空项再 Return 退出列表。
2. 检查标准有序／无序列表、编号从 9 到 10、缩进、段中分割、单步撤销／重做、模式关闭及围栏内普通换行。未编辑段仍保持排版。
3. 用真实中文候选确认／取消再换行，核对没有重复编号或打断组合输入；自动保存后重新打开并对照原文。真实 IME、长时间连续输入、长文滚动、完整 Finder 图片／视频往返、TCC 和 Intel 运行仍待人工验收。

已运行的旧评审进程不会自动载入新代码；保存草稿后重新启动评审应用才会使用最新构建。Dan 明确验收 FN-11 后才设 Done；本轮只回到 Review，不执行 Git 收尾或安装。
