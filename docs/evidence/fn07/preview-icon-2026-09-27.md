# FN-07 按钮精简与预览图标 · 2026-09-27

本次为 Dan 明确批准的界面调整，延续当前 FN-07 工作树与 `codex/fn-07-conflict-recovery` 分支。HEAD 仍为 `708c3f5a7b1ff31219ac53f339876fa7d793f890`，所有 FN-07 改动未提交、未推送、未合并，未启动 FN-08。之前的 [FN-07 首次交付](2026-09-27.md) 与 [高级选项补充记录](advanced-menu-2026-09-27.md) 及原始证据保留。

## 实现

底部现在为“保存、复制、导出、高级选项”。复制与导出仍调用原方法，分别复制完整草稿和生成 Markdown 快照；增加悬停说明“复制完整草稿”“导出 Markdown 快照”。文件菜单及保存面板中的 Markdown 格式说明未改。

预览切换移到左侧预览区右上方，使用原生 `sidebar.left` 线框符号，16 点配置、28×28 点点击区域、无文字及常驻边框。独立容器的顶部 32 点专用于图标；Quick Look 从其下方开始。收起后保留 32 点窄栏，图标仍可再次展开；正文获得其余空间（沿用两区之间 12 点间距）。悬停说明及无障碍名称随状态变为“收起预览／展开预览”，保留 `fn-toggle-preview`。

保留原预览释放／重载、焦点判断与编辑器实例，按钮仍拒绝夺取输入焦点。隐藏的预览内容退出布局，避免占位图标的最小宽度把折叠窄栏撑开；展开先切换宽度约束，再挂载内容。仅 `EditorWindowController.swift` 与两份使用／验收说明改变；相对上一交付的恢复 Store、Session、保存与冲突实现、测试文件和构建脚本哈希未变。窄范围差异见 `preview-icon-only.patch`。

## 回归与构建

环境：macOS 26.6.2（25G83）、Xcode 27.0（27A266a）、本机 APFS；使用 FN07 专用 Debug／Release 身份。

```sh
FINDERNOTES_BUILD_PROFILE=fn07 ./scripts/test_app.sh \
  -only-testing:FinderNotesTests/EditorWindowTests \
  -only-testing:FinderNotesTests/EditorAutosaveTests \
  -only-testing:FinderNotesTests/EditorRecoveryWindowTests \
  -only-testing:FinderNotesTests/EditorRecoverySessionTests \
  -only-testing:FinderNotesTests/DraftRecoveryStoreTests \
  -only-testing:FinderNotesTests/RecoveryFileIntegrationTests \
  -only-testing:FinderNotesTests/PreviewWindowTests \
  -only-testing:FinderNotesTests/MediaPreviewControllerTests
FINDERNOTES_BUILD_PROFILE=fn07 ./scripts/build_app.sh
codesign --verify --deep --strict .build/DerivedData/Build/Products/Release/FinderNotes.app
```

最终 **82/82 通过、0 跳过、0 失败**；包含 9 项真实文件 RecoveryFileIntegrationTests，其余为确定性／AppKit 测试。日志 `preview-icon-tests-final.log`，xcresult `.build/TestResults/FinderNotes-20260927-202953-67926.xcresult`。已有预览测试覆盖收起后的编辑区扩宽、程序化 marked text、选区／撤销保持、预览生命周期及焦点回到正文；不等同真实输入法或视频声音验收。本次未修改／新增测试，也未重跑完整 140 项。

初次候选也为 82/82 通过，保留 `preview-icon-tests.log` 与 `preview-icon-release.log`；随后只读审查指出展开时应先解除 32 点约束，再启用预览内容约束，已调整顺序并复跑最终结果。两轮均无测试失败；最终日志未出现 `Unable to simultaneously satisfy` 约束冲突。

最终 Release 构建与 codesign 核验通过，日志 `preview-icon-release-final.log`。应用仍为本工作树 `.build/DerivedData/Build/Products/Release/FinderNotes.app`，bundle ID `com.findernotes.FinderNotes.FN07Validation`。当前可执行文件 SHA-256：`d857cdd1e04a225521cb81c7c0ce6cc4c152362ab049f89ade5c1706a696c818`。前两份报告的二进制哈希分别属于各次历史交付，不能当作本次产物。

## 实机 UI 与独立样本

通过 `python3 -B validation/fn07/prepare.py` 创建全新根：
`/private/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/findernotes-fn07-6yh80imx`。
仅使用其中的合成 `work/portrait.png`，未读取或操作真实素材。没有输入新正文、写入笔记或改变测试文件权限。

| 场景 | 本次结果 |
| --- | --- |
| 空窗口切换 | 原生图标可收起，32 点窄栏保留展开入口，点击可恢复；按钮无障碍名称相应变化。`preview-icon-empty-collapsed.png`、对应 AX。 |
| Finder 打开合成文件 | 首先尝试顶部“访达 → 服务”后未见文件加载，继续定位未成功；改由文件右键“服务 → FinderNotes FN07 验收编辑笔记”后载入成功，随后真实 Quick Look 显示竖图。没有确认初次尝试的根因，不将此次结果描述为历史偶发空窗口已修复。 |
| 读取期间菜单 | 快捷菜单调用后的实际 AX 曾显示“正在读取笔记…”及高级选项禁用，后续完成加载后重新启用。该次观察只覆盖本次读取，不扩大为保存瞬间禁用已验证。 |
| 图标位置与分区 | 图标位于预览顶部靠正文一侧，Quick Look 在下方，正文与图标无重叠。`preview-icon-expanded.png`、`preview-icon-expanded-ax.txt`。 |
| 最小窗口宽度 | 原生拖动缩至 500 点宽（Retina 截图宽 1000 像素），展开及折叠状态的四个底部操作、预览开关均完整显示。`preview-icon-minimum-expanded.png`、`preview-icon-minimum-collapsed.png`。 |
| 正文与选区 | 选中合成正文，点击图标收起再展开，AX 选中内容保持一致，预览重新出现。`preview-icon-selection-before-ax.txt`、`preview-icon-selection-collapsed-ax.txt`、`preview-icon-selection-reexpanded-ax.txt`。 |
| 悬停提示 | 已设置两态原生 toolTip，并观察到无障碍名称切换；尝试停留指针未捕获系统浮动提示，**浮动提示目视检查仍未验证**。`preview-icon-expand-tooltip.png`、`preview-icon-tooltip-attempt.png` 仅为尝试画面，不作为浮层通过证据。 |

```sh
python3 -B validation/fn07/verify.py \
  /private/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/findernotes-fn07-6yh80imx \
  > docs/evidence/fn07/preview-icon-fixtures-final.json
```

13/13 文件的媒体哈希、身份、权限、自有 xattr 与无关 xattr 均与初始值一致。原始 JSON、截图、AX、新样本和当前验收窗口保留。原工作区仅原有 `AGENTS.md` 修改，SHA-256 仍为 `9b57a4f067e71f6554fee66e26f9551e2531e0bf9b32e5fe723d13ba0b237492`；未清理历史验收资源。

## 未验证项与 Dan 复验

真实中文输入法、声音、播放中收起停止、长文滚动，本次没有新增实测；继续保留历史未验证结论。存储、冲突交互的既有边界不变，xattr 检查加写入仍不是原子 CAS。本次顶部菜单尝试未成功的现象及悬停浮层未捕获分别记录，不用回归通过替代。

按 [更新后的验收步骤](../../../validation/fn07/README.md)，在当前合成竖图窗口检查“复制／导出”文案、图标位置、两态悬停提示、32 点窄栏和 500 点宽度，随后按原 FN-07 范围验收恢复／冲突流程。当前实现交付保持 Review，只有 Dan 明确接受后设 Done；不提交、推送、合并或启动 FN-08。
