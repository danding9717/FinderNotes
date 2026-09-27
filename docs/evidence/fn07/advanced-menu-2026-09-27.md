# FN-07 高级选项补充交付 · 2026-09-27

本记录补充同日 [FN-07 首次交付](2026-09-27.md)，不改写其历史日志、锁屏阻挡记录或未验证结论。此次仅按 Dan 已确认方案将低频入口移入原生菜单。使用既有 `codex/fn-07-conflict-recovery` 工作树，HEAD 仍为 `708c3f5a7b1ff31219ac53f339876fa7d793f890`；全部 FN-07 改动未提交、未推送、未合并，未启动 FN-08。

## 实际变更

- 移除第二行按钮；第一行保留保存、复制草稿、导出 Markdown、收起／展开预览，右侧增加 `NSPopUpButton(pullsDown: true)` 高级选项。
- 菜单项“核对外部版本…”与“恢复草稿（数量）…”直接调用原方法；显式禁用 AppKit 自动启用菜单项。核对须已有文件；恢复只需恢复 store，空窗口仍可进入。读取、保存、导出或确认时两项与整个下拉按钮均禁用；原组合态保护不变。
- 保留恢复数量的原有读取时机，不引入扫描或数量刷新策略变更。冲突及恢复暂停指引改为“高级选项 → 核对外部版本”；状态区仍显示错误／暂停原因。
- 同行间距改为 6 点，支持既有 500 点最小窗口宽度；不缩写操作名称。使用说明与 [Dan 验收步骤](../../../validation/fn07/README.md) 已同步。
- 与首次交付的 SHA-256 清单比较，只有 Controller、Session 的提示文案、两份说明及 Release 可执行文件改变；恢复 store、格式、测试、构建身份及脚本未变。`advanced-menu-only.patch` 保存前三个已跟踪文件相对首次交付的窄范围差异。

## 验证

环境：macOS 26.6.2（25G83）、Xcode 27.0（27A266a）、本机 APFS，FN07 专用身份。

```sh
FINDERNOTES_BUILD_PROFILE=fn07 ./scripts/test_app.sh \
  -only-testing:FinderNotesTests/EditorWindowTests \
  -only-testing:FinderNotesTests/EditorAutosaveTests \
  -only-testing:FinderNotesTests/EditorRecoveryWindowTests \
  -only-testing:FinderNotesTests/EditorRecoverySessionTests \
  -only-testing:FinderNotesTests/DraftRecoveryStoreTests \
  -only-testing:FinderNotesTests/RecoveryFileIntegrationTests \
  -only-testing:FinderNotesTests/PreviewWindowTests
FINDERNOTES_BUILD_PROFILE=fn07 ./scripts/build_app.sh
codesign --verify --deep --strict .build/DerivedData/Build/Products/Release/FinderNotes.app
```

最终 **73/73 通过，0 跳过，0 失败**：EditorWindow 11、Autosave 10、RecoveryWindow 12、RecoverySession 15、DraftRecoveryStore 12、PreviewWindow 4；真实文件 RecoveryFileIntegration 9 单独计入上述总数。日志 `advanced-menu-tests-final.log`；xcresult `.build/TestResults/FinderNotes-20260927-195236-53857.xcresult`。初次候选也为 73/73，保留 `advanced-menu-tests.log`；调整间距和冲突提示后复跑。此次未重跑完整 140 项，不把历史全套结果当成新结果。

Release 构建和签名核验成功，日志 `advanced-menu-release-final.log`；初次构建日志 `advanced-menu-release.log` 保留。当前应用仍在本工作树 `.build/DerivedData/Build/Products/Release/FinderNotes.app`，身份 `com.findernotes.FinderNotes.FN07Validation`；可执行文件 SHA-256：`d52c3111af3383d008ca3310adaa8ab7e48638642e6bffb4e38868b83fc3acde`。旧报告中的应用哈希属于第一次交付；当前源码／产物／新增证据哈希见 `advanced-menu-sha256.json`。

## Finder / UI 实测

本次 CUA 可正常操作，新增证据单独记录；旧的 `ui-attempt.json` 锁屏失败原样保留。

使用 `python3 -B validation/fn07/prepare.py` 新建根：
`/private/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/findernotes-fn07-f3mu6lvu`。
只打开其中 `work/readonly.png`，通过 Finder → 服务 → FinderNotes FN07 验收编辑笔记进入，未操作历史样本或真实素材。

| 检查 | 实际结果与证据 |
| --- | --- |
| 空窗口高级选项 | 核对外部版本禁用，恢复草稿可用；`advanced-menu-empty-ax.txt`、`advanced-menu-empty.png`。初次候选点击无记录入口显示“没有已落盘的待恢复草稿”，返回编辑正常。 |
| 载入后菜单点击 | 两项可用；核对外部版本进入原有四选项对话框，点击继续编辑后草稿保留，按钮标题仍为高级选项。`advanced-menu-loaded-ax.txt`、`advanced-menu-check-sheet-*`。 |
| 最小宽度 | 初次 10 点间距导致窗口只能缩至约 512 点，保留 `advanced-menu-initial-minimum.png`。改为 6 点后可缩到 500 点（截图宽 1000 像素，Retina 2×）；展开／收起预览、恢复长提示时按钮均完整且不重叠，状态提示自动换行。`advanced-menu-minimum-expanded.png`、`advanced-menu-minimum-collapsed.png`、`advanced-menu-minimum-recovered.png`。 |
| 导出／确认 | 核对对话框是原生模态 sheet；导出面板显示时底部按钮不可操作，截图可见高级选项灰显。取消导出后高级选项恢复可用，草稿不变。`advanced-menu-export-sheet-*`、`advanced-menu-export-cancelled-ax.txt`。确认期间未单独读取被 sheet 遮蔽的菜单项 isEnabled。 |
| 恢复数量与入口 | 在 0444 合成文件输入草稿，自动保存按预期报 Permission denied 并暂停，恢复 JSON 已落盘。只对本次所启、完整路径核对的 FN07 进程 PID 54260 发送 SIGKILL，确认旧 PID 消失；重启同一应用，在空窗口看到“恢复草稿（1）…”。点击菜单、选择恢复后，合成文本完整出现、自动保存仍暂停，状态指向高级选项。`advanced-menu-restart.json`、`advanced-menu-recovery-count-*`、`advanced-menu-recovery-chooser-*`、`advanced-menu-recovered-*`。这次新增真实 App/UI 已落盘草稿恢复证据，仅覆盖该样本。 |

SIGKILL 前先读取并核对恢复记录的目标、格式与合成草稿，备份只放在本轮合成根的 `evidence/advanced-menu-before-restart.json`；普通结果报告只存哈希。重启后的 UI 原始 AX／截图包含本轮合成文本，不含真实用户正文。只承诺已落盘草稿；粘贴不代表真实中文输入法测试。

```sh
python3 -B validation/fn07/verify.py \
  /private/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/findernotes-fn07-f3mu6lvu \
  > docs/evidence/fn07/advanced-menu-fixtures-final.json
```

13/13 样本与初始媒体、文件身份、权限、自有 xattr 和无关 xattr 一致。验证后保留验收窗口中的合成恢复草稿、恢复记录、新样本与全部证据，不清理历史资源。`readonly.png` 仍为 0444。

## 失败、未验证和风险

- 首次布局实际下限约 512 点的问题已通过缩小按钮间距修正，并有 500 点实机截图；没有测试失败或构建失败。初次及最终日志均保留。
- 读取／保存操作转瞬之间的菜单禁用状态未捕获实机画面；启用条件按源码核对保持原条件，相关回归通过，但不将源码核对记作实机覆盖。
- 原 FN-07 其他 UI 冲突两方导出／覆盖、删除／替换／移动等完整路径未在此次菜单调整中重做；历史确定性／真实文件证据保留，不能把这次入口验证扩大成所有交互通过。
- 真实中文输入法、声音、播放中收起停止、长文滚动本次没有新增实测，继续未验证；TCC、跨卷／云盘、正式分发及历史服务边界不变。0444 失败不是 TCC 拒绝。
- 恢复格式与持久化保证不变，xattr 检查加写入仍不是原子 CAS。没有扩展系统权限、后台扫描、第二套笔记库、日志正文上传。

## Dan 复验

当前应用和最小宽度的合成恢复窗口已保留。按 [验收步骤](../../../validation/fn07/README.md) 先复核高级选项的两个入口、恢复数量、取消返回、空窗口及最小宽度，再继续原 FN-07 冲突／恢复验收；不把此次粘贴或读取回归替代真实输入法。实现保持 Review，只有 Dan 明确接受才设 Done。
