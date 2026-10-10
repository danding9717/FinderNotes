# FN-11 输入稳定性修正

> 后续任务列表交互补充见 [TASK_LIST.md](TASK_LIST.md)。下文保留对应阶段的历史结果，不代表新增任务交互的最终结论。

日期：2026-10-10。任务：[FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。本页记录 Dan 反馈“输入时已有内容在源码和排版间反复切换”后的修正；[首轮交付证据](VALIDATION.md)保留为历史记录。

后续列表回车续写交付见 [LIST_CONTINUATION.md](LIST_CONTINUATION.md)。本页的 1180 条结果为稳定性修正时的历史快照；其 compile／result 日志已保留至 `.build/FN11Evidence/stability-verification/`，共享验证日志以最新轮次为准。

## 实际完成

继续采用当前逻辑段落显示源码、其他段落保持排版的已确认规则；跨段选区和整个代码围栏继续展开。连续输入不再清空整篇属性及隐藏范围。交互参考 [Obsidian Live Preview](https://obsidian.md/help/edit-and-read)，实际实现仍按本任务的整段展开范围。

- `NSTextStorageDelegate.willProcessEditing` 是实际字符变化的唯一记录入口；使用主线程隔离的协议遵循。回调只验证编辑差量、映射缓存和显示元数据，不修改文字属性、选区或滚动。
- 新增 `MarkdownTextEdit`：核对 AppKit 新范围、长度差和旧／新 UTF-8 原文，必要时用公共前后缀重新计算；边界保持完整 Unicode scalar，避免在代理项中间切开。新插入内容不继承旧隐藏范围。
- 新增 `MarkdownDisplayPlan`：完整逻辑段同时缓存展开／折叠样式、相对标记及装饰。保留且移动未编辑段，仅丢弃受编辑影响或不再完整的段。原生编辑完成后更新受影响显示；后台仍全文解析，比较段计划后只写实际变化段的属性。
- 解析未完成时可通过缓存展开新进入的未改段，移出后恢复折叠。`setMarkedText`、`insertText`、`unmarkText` 成对标记原生调用边界；组合输入期间暂停属性更新，保留其他段排版，确认／取消及无字节变化提交后恢复。继续核对文件代次、编辑 revision、解析代次及精确原文字节。
- 回归发现进入已排版标题后，显示字体为 28pt，但原生输入字体仍为 16pt，导致首批字符暂时缩小。现仅从匹配当前原文的完整当前段缓存同步输入属性，处理标题行末 CR/LF 和空段；脏段无有效缓存时保留原生输入属性。此修正不修改正文或增加撤销项。

完整新语法及受围栏变化影响的段，仍在解析完成后更新到正确显示；新增尚未解析的段可能暂时继承原生输入字体。本次不承诺新语法在后台解析前已经完成识别。原文保存、复制、导出、恢复、存储格式、公共接口及 swift-markdown 0.9.0 保持现状。

## 当前代码与环境

目录 `/Users/danding/Project/AI/FinderNotes`，分支 `codex/fn-11-markdown-layout`，基线 `235b13f26b640e063c113ce40b30eae72f498ae4`。保留首轮及本轮未提交改动；未提交、推送、合并或安装，无 PR，仅处理 FN-11。

macOS 26.7.1（25G241）、Apple M2／arm64、Xcode 27.0（27A266a）、Swift 6.4、SDK 27。Release 构建 arm64／x86_64，组件运行只覆盖当前 arm64 主机。评审产物位于 `.build/FN11/Build/Products/Release/FinderNotes.app`，身份 `com.findernotes.FinderNotes.FN11Review`，独立服务名“FN11 Markdown 测试（隔离副本）”；未覆盖 LocalTrial。

## 实际验证

在仓库根目录执行：

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

最终 Release 构建、严格签名验证及 diff 检查通过；最终组件检查通过 **1180 条断言**，无剩余失败。构建只有未依赖 AppIntents 的元数据提取跳过警告。验证使用生产源文件、隔离偏好域、隐藏 AppKit 窗口和独立合成文件。

新增的可控解析 gate 阻断真实解析结果，逐次检查原生输入完成后、解析阻断中、结果应用后三个阶段。远段字体及其他属性、隐藏标记、实际 glyph manager 遮罩和列表／引用装饰均保持一致，storage 通知及局部写入范围证明没有重写远段属性。覆盖：

- 段首／段中插删、emoji UTF-16 增删、组合字符、CRLF、多段插入、换行合并和撤销重做；编辑差量含 91 条纯映射检查。
- 解析期间移动光标、旧／新段展开与折叠，当前段源码持续可见，新字符不被旧遮罩误隐藏。
- 模拟 marked text 增长／缩短、无字节变化提交、取消，以及组合输入期间旧解析结果真正返回后的隔离。
- 围栏编辑、180 项列表中的局部编辑与语义更新；最终显示对照完整新解析计划。
- 标题段中、LF 前行末及后续空段首次输入与解析阻断期间的字号／字体；模式关闭／开启的滚动坐标。
- 原有全文原文字节、复制、Markdown 导出、恢复、临时 xattr 手动／自动保存及旧保存期间继续输入检查均重新通过。

最终三张组件位图已实际查看，并通过隐藏 glyph 零 advance 和 EOF 分隔线位置检查。它们是程序化 AppKit 渲染，不能代替真实连续输入画面。组件临时合成文件和隔离偏好已清理，无测试进程或运行锁残留。

日志：`.build/FN11Evidence/stability-build-final.log`、`.build/FN11Verification/compile.log`、`.build/FN11Verification/result.log`。本轮源文件、最终应用和测试日志 SHA-256：`.build/FN11Evidence/stability-sha256.txt`。首轮 SHA-256 清单只对应首轮，不作为本次构建证明。

## 失败修正与真实 UI 边界

修正过程中发现并处理了标题首次输入字号问题。一次模拟 IME 测试错误地禁止了所有属性通知，AppKit 自身会给候选区添加 marked-clause 属性；测试改为禁止远段属性写入并逐步核对远段内容，随后通过。其余首轮历史问题保留在 VALIDATION.md。

本轮实际启动了独立评审构建，确认空窗口和 Markdown 开启状态。使用 Finder 导航到了本轮合成文件目录；在选择文件／服务调用时，共享 Finder 界面被切换回桌面，工具要求重读状态。重读确认已离开测试目录后停止共享 Finder 操作。本轮未完成服务加载后的连续输入，不能据此声称最终修正的真实 UI 或中文候选输入已通过。

保留的 UI 测试副本：`/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/FinderNotes-FN11-StabilityUI-rhybls1m/stability-test.png`；同目录 `original.md` 是原始正文。该文件包含标题、强调、链接、引用和列表，不是真实素材。

仍待 Dan 实测：真实中文输入法候选／确认／取消、快速长时间连续输入、鼠标跨段拖选、长文自然滚动、最终构建完整 Finder 图片／视频往返、外部富文本粘贴、恢复 UI、TCC 和 Intel 运行。程序化组合输入及确定性中间态检查不替代上述结论，也没有给出延迟或性能阈值。FN08-I07／I08、xattr 非原子 CAS 及仅保护已成功落盘草稿的既有边界保留。

## Dan 的验收操作

1. 从上述副本运行明确命名的隔离服务，确认评审窗口路径。把光标放在最后“当前编辑段”后，连续输入中文、候选切换／确认／取消及 emoji；观察标题、粗体、链接、引用和列表始终保持排版，没有整篇源码中间态。
2. 在段首、段中和行末编辑，换行／合并、多段粘贴、撤销／重做；移动光标和跨段拖选，确认仅涉及的段落展开，选区稳定，新字符可见。
3. 使用临时副本加入长列表及代码围栏，连续编辑单项，增删围栏并长文滚动；检查后文自然移动，语义受影响部分更新一次。切换 Markdown 和文件后，旧解析结果不得覆盖当前内容。
4. 检查原文复制、手动／自动保存、保存期间继续输入、导出和恢复。明确验收 FN-11 后才设 Done；本次不启动其他任务，Git 收尾及安装需另行授权。
