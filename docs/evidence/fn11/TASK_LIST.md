# FN-11 任务列表交互

> 后续底部“源码模式 / 实时阅览”菜单调整见 [MODE_MENU.md](MODE_MENU.md)。下文保留任务列表交互阶段的证据与边界。

日期：2026-10-10。任务：[FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。Dan 反馈 `- [ ] ` 任务列表无法使用，并明确确认“可点击勾选，并回车续写”。本轮仅在 FN-11 内追加该范围，保留列表续写、输入稳定性和最初交付的历史证据。

## 行为与边界

- 当前编辑段仍显示 Markdown 源码；光标离开后，标准任务项显示复选框。点击复选框只切换原文状态 `[ ]` / `[x]`，已有 `[X]` 同样可取消。
- 有内容的任务项 Return 生成未勾选的新任务项，保留列表标记、缩进、分隔空白和换行样式。已勾选项不会使新项默认勾选。
- 空任务项 Return 删除当前项前缀并退出；任务标记内部光标、跨段选区、组合输入和代码围栏仍使用原生行为。
- 正文继续是原始 UTF-8 Markdown；保存、复制、导出与恢复格式不变。表格、图片、公式、HTML、通用补全、引用续写和后项重编号不扩展。

## 实现与验证

实现继续沿用 swift-markdown 0.9.0 与原始正文通路。解析器只接受已核对的任务项前缀；显示计划缓存复选框状态与精确 UTF-16 状态字符范围。布局器共用绘制与命中矩形，点击通过一次原生字符编辑切换状态，并恢复原选区和滚动位置。解析延迟时，状态缓存与段落范围映射立即保持显示；代码围栏、公式或 HTML 等结构变化暂缓后方旧复选框点击，接受新解析后恢复。组合输入期间不执行点击或自动续写。

本轮保留并扩充现有组件检查：实际鼠标事件、撤销重做、空 EOF 任务、引用任务、emoji 和组合字符位移、延迟解析中点击与结构语义保护、自动保存精确原文及媒体字节不变。测试使用独立 PNG/xattr、UserDefaults 和临时目录。最终标准套件通过 **2155 项断言**，包括新增的延迟解析期间公式起始标记保护。环境为 macOS 26.7.1（25G241）、M2 / arm64、Xcode 27.0（27A266a）、Swift 6.4；Release 应用构建包含 arm64 / x86_64，实际检查仅运行 arm64。严格 codesign 与 whitespace 检查通过。构建唯一提示为未依赖 AppIntents.framework，跳过相关元数据提取。

实际命令（从仓库根目录执行）：

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11TaskReview" ./scripts/build_app.sh \
  FINDERNOTES_APP_SUFFIX=.FN11TaskReview \
  INFOPLIST_FILE="$PWD/.build/FN11TaskReview-Info.plist" \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages" \
  -disableAutomaticPackageResolution
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11TaskReview" \
  FINDERNOTES_FN11_SKIP_BUILD=1 FINDERNOTES_CONFIGURATION=Release scripts/verify_fn11.sh
codesign --verify --deep --strict --verbose=2 .build/FN11TaskReview/Build/Products/Release/FinderNotes.app
git diff --check
```

最终组件结果、编译日志和空 EOF 任务位图保存在 `.build/FN11Evidence/task-final-verification/`；最终构建日志为 `.build/FN11Evidence/task-build-final.log`。源码、证据和应用二进制 SHA-256 清单为 `.build/FN11Evidence/task-sha256.txt`。应用身份为 `com.findernotes.FinderNotes.FN11TaskReview`，仅位于 `.build/FN11TaskReview/Build/Products/Release/FinderNotes.app`，没有安装或替换其他正在运行的版本。

真实 UI 使用单独的 FN11 task UI harness、生产编辑器和独立 PNG/xattr 副本，未操作用户媒体。CUA 实际鼠标点击验证勾选与取消；实际 Return 验证已勾选项续写未勾选项、空项退出；原生编辑菜单快捷键验证撤销与重做；鼠标定位光标后，逐键输入 `t e s t` 得到 `2. [ ] test`，其他段仍显示复选框与标题排版。自动保存后，以 xattr 十六进制读回精确原文相等，PNG 字节未变。原文与哈希记录保存在 `.build/FN11Evidence/task-ui-final-record.json`。这是短程串行 UI 样本，不能代替真实中文输入法、长时间输入、长文滚动、Finder/TCC、Intel 运行或安装版验收。

修正过程中保留两次失败记录：撤销会按原生规则移动光标，测试现明确区分撤销选区与点击保留选区；swift-markdown 对引用内任务未提供 checkbox 元数据，现仅在 AST 引用列表节点内验证精确源码并补足显示，不扫描普通段落。带 HTML 的引用混合内容继续保守显示源码。UI 验收 harness 的事件循环问题仅在测试入口修正：最终保留原组件异步入口，只为显式 UI 构建提供同步 NSApplication 主循环。临时共用同步入口曾触发已有隐藏窗口滚动断言失败，未放宽断言；分离入口后的最终标准套件通过 2155 项。该失败说明与早期解析／撤销失败保存在 `.build/FN11Evidence/`，不据此声称真实长文滚动已通过。自动化文本定位曾因富文本辅助功能表示偏移而把测试字符放进下一行标记，已撤销并改用实际鼠标定位验证；生产代码未为此修改。

## 人工验收步骤

1. 在独立测试副本输入 `- [ ] 待办`，移到其他段落，点击复选框勾选、取消并撤销／重做；核对光标和其他段的字体、标记隐藏及装饰稳定。
2. 分别从未勾选项、已勾选项回车，下一项都是 `- [ ] `；空任务项再回车退出。测试缩进、CRLF、正文中间换行及围栏内普通换行。
3. 使用真实中文输入法确认／取消候选，继续编辑和滚动；保存后重开，核对完整原文、复选框状态及媒体内容。

未提交、推送、合并或安装；人工验收前不设 Done，不启动其他任务。
