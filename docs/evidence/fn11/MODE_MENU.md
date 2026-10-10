# FN-11 底部编辑模式菜单

> Dan 已于 2026-10-10 明确验收当前交付；对象与保留边界见 [ACCEPTANCE.md](ACCEPTANCE.md)。下文保留实施时的检查记录。

2026-10-10：按 Dan 提供的当前界面与 Obsidian 截图，将顶部 Markdown 按钮移到下方，并明确为“源码模式”“实时阅览”两项。任务仍为 [FN-11](https://app.notion.com/p/3f5e7607d64981e19183dc1d6260ba03)。

## 本轮改动

- 编辑区下方工具栏右端采用原生弹出菜单，显示当前模式和图标；菜单仅有两项，当前项带勾选。
- 顶部仅保留原有置顶按钮。选择模式直接设置对应状态，重复选择当前模式保持不变。
- 沿用原排版状态和 `markdownLayoutEnabled` 偏好，首次仍默认实时阅览。切换只改变显示，不主动改变正文、选区或编辑焦点。
- 生产代码本轮只修改 `FinderNotes/EditorWindowController.swift`；原有 FN-11 未提交实现与测试全部保留。

## 实际验证

macOS 26.7.1 / Apple M2 / Xcode 27.0 / Swift 6.4。Release 双架构构建通过，严格 codesign 和 `git diff --check` 通过；实际运行仅覆盖 arm64。唯一构建提示为无 AppIntents.framework 依赖而跳过其元数据提取。

```sh
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11TaskReview" ./scripts/build_app.sh \
  FINDERNOTES_APP_SUFFIX=.FN11TaskReview \
  INFOPLIST_FILE="$PWD/.build/FN11TaskReview-Info.plist" \
  -clonedSourcePackagesDirPath "$PWD/.build/FN11/SourcePackages" \
  -disableAutomaticPackageResolution
FINDERNOTES_DERIVED_DATA="$PWD/.build/FN11TaskReview" \
  FINDERNOTES_FN11_SKIP_BUILD=1 FINDERNOTES_CONFIGURATION=Release scripts/verify_fn11.sh
```

现有组件套件再次通过 **2155 项断言**，没有新增或放宽断言。另以 `FINDERNOTES_FN11_BUILD_TASK_UI=1` 编译独立 UI harness，经 CUA 启动并操作生产编辑器，仅使用临时 PNG/xattr 和独立偏好副本。

真实 UI 检查：顶部无 Markdown 按钮；右下角菜单只有两项，勾选与按钮文字随选择更新；源码模式显示完整标记，实时阅览恢复原地排版；重复选择源码模式不反转；切换前后焦点仍在正文；缩到 500×360 窗口且预览展开时，底部各控件完整可见、没有重叠。分别独立读取偏好值为 0 / 1，xattr 原文均与初始字节相等，状态未变为草稿修改或保存成功。

构建、编译、组件结果、UI 回读记录、本轮改动前源码和 SHA-256 清单保存在 `.build/FN11Evidence/mode-menu/`。验收应用为 `.build/FN11TaskReview/Build/Products/Release/FinderNotes.app`，身份 `com.findernotes.FinderNotes.FN11TaskReview`；该路径现在包含本轮底部菜单调整，历史任务列表阶段的哈希不代表当前构建。

真实中文候选输入期间切换、长期滚动、Finder/TCC、Intel 运行及安装版体验仍保留原未验证边界。本轮未提交、推送、合并或安装，未启动其他任务；等待 Dan 人工验收后再决定 Done。

## Dan 验收

打开本轮构建，在右下角切换“源码模式 / 实时阅览”，检查显示、光标与输入体验；退出重开核对记忆的模式。继续使用测试副本完成真实中文输入法和长文体验验收。
