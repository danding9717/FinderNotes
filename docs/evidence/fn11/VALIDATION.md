# FN-11 Markdown 原地实时排版验证

> 后续任务列表交互补充见 [TASK_LIST.md](TASK_LIST.md)。下文保留对应阶段的历史结果，不代表新增任务交互的最终结论。

日期：2026-10-10。任务：[FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。

本页保留首轮功能交付证据。后续输入稳定性修正、当前构建与回归结果见 [STABILITY.md](STABILITY.md)；原 318 项检查和 UI 观察不代表修正后的最终验收。仅处理 FN-11。

## 验证对象

- 工作目录：`/Users/danding/Project/AI/FinderNotes`；分支 `codex/fn-11-markdown-layout`；基线 `235b13f26b640e063c113ce40b30eae72f498ae4`。本轮代码未提交、未推送，无 PR；未安装或覆盖当前应用。
- macOS 26.7.1（25G241）、Apple M2 / arm64、Xcode 27.0（27A266a）、Swift 6.4。Release 同时构建 arm64/x86_64；运行检查只在当前 arm64 主机执行。
- [swift-markdown 0.9.0](https://github.com/swiftlang/swift-markdown/releases/tag/0.9.0) 使用 Xcode `exactVersion`；共享 `Package.resolved` 同时锁定 swift-markdown 与 swift-cmark 的 0.9.0 和提交。运行时不调用外部 API。

## 实现与证据边界

现有 NSTextView 显式使用 TextKit 1，正文仍是原始字符串。字体、段落、颜色和删除线使用显示属性；标记通过 NSLayoutManager 的 `.null` 字形折叠。列表、引用与分隔线在布局层绘制。当前段落和跨段选区保留源码，进入代码围栏任意位置展开整块。模式切换不重建编辑器、不调用正文修改通知、不添加撤销项；首次默认开启，并通过 UserDefaults 记忆选择。

首轮解析在后台执行，以任务代次、源文完整 UTF-8 字节及输入状态核对结果。首轮编辑前清除旧标记范围，这一实现导致输入时整篇显示切换，已在后续稳定性修正中替换为按段缓存和局部更新；组合输入期间暂停属性排版。源位置严格从 UTF-8 列转换为 UTF-16；隐藏前验证真实标记，不能可靠定位时保留源码。表格、任务列表、图片、HTML 和公式保留源码。

保存、草稿复制、Markdown 快照导出和恢复仍使用完整原文；没有改变 xattr 格式、保存确认、失败保护或恢复格式。媒体预览与 Markdown 开关分别工作。TextKit 临时属性不支持字体／段落布局，因此这些显示属性写入 NSTextStorage，但不改变字符；依据见 [Apple Text Attributes](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextAttributes/AboutTextAttributes.html)。

## 实际命令与构建

在仓库根目录执行：

```sh
./scripts/verify_toolchain.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -resolvePackageDependencies -project FinderNotes.xcodeproj -scheme FinderNotes \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages"
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11" ./scripts/build_app.sh \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages" \
  -disableAutomaticPackageResolution
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11" ./scripts/build_app.sh \
  FINDERNOTES_APP_SUFFIX=.FN11Review \
  INFOPLIST_FILE="$PWD/.build/FN11Review-Info.plist" \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages" \
  -disableAutomaticPackageResolution
FINDERNOTES_FN11_SKIP_BUILD=1 FINDERNOTES_CONFIGURATION=Release ./scripts/verify_fn11.sh
git diff --check
```

标准 Release 及最终隔离身份 Release 构建均通过；最终产物的 `codesign --verify --deep --strict --verbose=2` 通过。最终隔离构建包含分隔线范围、列表绘制位置、文末无换行分隔线及代码围栏结尾插入点的修正。当前评审产物为 `.build/FN11/Build/Products/Release/FinderNotes.app`，身份 `com.findernotes.FinderNotes.FN11Review`，显示名 FinderNotes FN11 Review；它不是已安装的 LocalTrial。最终构建已实际启动，空窗口与 Markdown 开启状态正常。构建仅有未依赖 AppIntents 的元数据提取跳过警告。构建日志及源文件／产物 SHA-256 清单位于 `.build/FN11Evidence/`，组件编译／结果日志及位图位于 `.build/FN11Verification/`。

## 组件检查

测试代码和复跑入口位于 `tests/FN11/`、`scripts/verify_fn11.sh`。组件检查使用隔离偏好域、隐藏测试窗口及独立临时合成 PNG，不操作真实媒体、旧 Orbit 或安装件。通过项包括：

- 全部支持语法、嵌套强调、未闭合和未支持语法；中文、emoji、组合字符、CRLF 的源位置和范围边界。
- 源文完整字节、正式 xattr 回读、媒体内容、Markdown 导出、恢复记录与恢复会话的一致性。
- 显示字体、当前段与跨段／多选区、整个代码围栏展开、模式切换、滚动坐标及撤销重做。
- 模拟 marked text 期间不排版、无字节变化的提交，以及旧解析结果、同字节换文件和 Unicode 规范等价但字节不同的隔离。
- 真实 EditorWindowController 的原生 textDidChange 路径、独立偏好及剪贴板；开关不改变 revision／状态、不触发保存；原生选区复制和完整草稿复制保留标记。
- 实际 NoteWriter 写入临时 xattr 的自动／手动保存；阻塞旧保存时继续输入，旧完成只推进已确认基线，下一次自动保存完整新草稿。
- 生产布局管理器的 `.null` 字形与零水平 advance；普通排版位图及无尾随换行分隔线位图的像素行位置。

最终整套通过 **318 项断言**，无剩余失败。命令是上列 `FINDERNOTES_FN11_SKIP_BUILD=1 FINDERNOTES_CONFIGURATION=Release ./scripts/verify_fn11.sh`。组件模拟不等于真实输入法、鼠标拖选或 Finder 系统权限验收。

以下是生产 NSTextView 的程序化组件渲染，已实际查看；不是 Finder 使用截图。EOF 图使用生产布局管理器构造全隐藏末行，并校验分隔线位于自己的行。

![支持语法与源码保留的组件位图](/Users/danding/Project/AI/FinderNotes/docs/evidence/fn11/layout.png)

![文末无换行分隔线的组件位图](/Users/danding/Project/AI/FinderNotes/docs/evidence/fn11/rule-eof.png)

## 实际 UI 观察

使用独立身份 FN11Review，通过 Finder 的 `FN11 Markdown 测试（隔离副本）` 服务打开本轮临时 PNG，窗口确认了测试路径及完整原文。实际观察到标题、粗体、斜体、删除线、链接、代码样式和未支持内容保留源码；将插入点移到引用段后，该段的 `>` 可见，标题标记折叠。

首次启动 Markdown 为开启；通过真实开关关闭、退出再启动仍为关闭；重新开启、退出再启动仍为开启。上述偏好仅写入 FN11Review 的独立域。

第一轮画面暴露分隔线未排版和列表标记偏移，均已修正并增加相应检查。后续 Finder 操作与另一个正在使用 Finder 的会话发生界面切换，停止共享 Finder 重试；不能据此声称最终构建完成整套 Finder／输入法验收。最终修正的排版另有组件渲染位图核对。

## 失败、修正及未验证项

- 初始构建因 `CGFloat.greatestFiniteMagnitude` 的类型歧义及 Swift 6 的布局回调隔离声明失败；修正后构建通过。保留前两次失败日志，不把重试写成首次成功。
- 分隔线节点的源范围包含换行，原验证过严导致源码未折叠；修正为只验证／隐藏该行内容。列表的空字形原被分配到前一行，绘制改为锚定首个可见正文字符。
- 无末尾换行的全隐藏分隔线原会锚定上一行；改用 TextKit 的末尾额外行框，没有额外行框时保留本行定位。光标在闭合围栏末尾时按当前段落交集展开整个代码块。
- 测试脚本曾因并行源码编辑而中断编译；模拟撤销分组、测试视图宽度及窗口 ARC 生命周期配置已修正。原生剪贴板写入改用 NSTextView 实际声明的旧式纯文本类型，回读 `.string` 验证原文；字形断言按原始字符过滤范围并比较水平位置，避免把相邻空格或 ink bounds 误当隐藏字形宽度。以上是测试夹具修正，最终整套通过。
- 真实中文输入法候选／确认上屏、鼠标拖选、键盘长时间连续操作、外部应用富文本粘贴、长文实际滚动与悬停、最终构建的完整 Finder 图片／视频往返、恢复 UI、TCC、Intel 运行仍待 Dan 实测。
- 程序化 marked text、布局位图、隐藏窗口及合成文件读写不替代这些真实使用结论。FN08-I07／I08 及历史失败、跳过、未验证项保留；xattr 检查与写入仍不是原子 CAS，恢复仍仅保护成功落盘的草稿。

## Dan 的验收步骤

1. 使用独立评审应用和临时合成图片／视频；通过明确的隔离服务确认窗口路径，避免对真实素材写入。验证首次默认、关闭／开启后退出重启的记忆。
2. 输入各支持语法并移动光标；检查当前段、跨段选区与整个围栏展开，移出后重新折叠；表格、勾选框、图片、未闭合内容保留源码。
3. 使用真实中文输入法候选、emoji、组合字符；进行鼠标拖选、键盘移动、撤销重做、长文滚动与模式切换，确认原文和编辑位置不丢失。
4. 从其他应用粘贴 Markdown 源码，核对复制、导出、手动／自动保存、保存期间继续输入、重新打开和草稿恢复后的完整原文。分别操作媒体预览与 Markdown 开关。
5. 有问题先保留草稿及实际提示；通过后明确确认 FN-11。仅在 Dan 验收后设 Done，Git 收尾按另行授权执行；本轮不启动其他任务。
