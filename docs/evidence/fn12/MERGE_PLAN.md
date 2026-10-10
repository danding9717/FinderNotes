# FN-12 与已合并 FN-11 的整合审阅

FN-12 验收源：`c2f425371441af21d542856e2db6a854677ecf57`，基线 `235b13f`。
当前 main：`74e5428484e08a3406a0ffd443d3a3008d2f59d1`（FN-11 / PR #14）。
待合并 PR：https://github.com/danding9717/FinderNotes/pull/15

`git merge-tree --write-tree HEAD origin/main` 实际报告三个冲突；该检查没有在工作树开始合并。GitHub 返回 `mergeable=CONFLICTING`、`mergeStateStatus=DIRTY`。main 端点返回 protected=false / status-check enforcement off；protection 与 rulesets 明细 API 返回 403，不能声称存在已核验保护规则。PR 当前没有检查或审阅结果。

需要 Dan 另行授权的最小整合范围：

1. `FinderNotes.xcodeproj/project.pbxproj`：保留 FN-11 的 Markdown 文件／SwiftPM 引用和全部构建设置，为 FN-12 的更新协调与审计、Sparkle 包分配不碰撞的新 PBX ID，并将两方 Sources、Frameworks、packageReferences、packageProductDependencies 合并。不能整文件选择 ours／theirs；相同编号目前指向不同对象。
2. `Package.resolved`：合并 Sparkle 2.10.0、swift-markdown 0.9.0 和 swift-cmark 0.9.0 的已验收 revision；由组合工程运行依赖解析并核验版本不漂移。
3. `EditorWindowController.swift`：保留 FN-11 的原地 Markdown 排版、列表及任务项输入／稳定编辑逻辑，同时保留 FN-12 的更新 UI 期间窗口层级协调和组合输入／保存／导出退出保护，逐处审阅冲突。

获得授权后，先合入当前 main 处理这三个文件，再检查最终差异；构建 standard／LocalTrial 并执行适合这次整合的 FN-11 与 FN-12 回归，记录新整合提交，不把原独立验收包冒充组合包。检查通过后按最终 PR head 约束合并，不修改其他功能、不发布、不启动下一任务。

计划提出时尚未解决冲突或进行合并。Dan 随后明确回复“授权处理这三个冲突并继续标准收尾”，允许按上述最小范围整合、回归并继续合并。FN-12 已验收和 Notion Done 保留，实际结果另记。

## 授权后的实际结果

三个冲突已逐处整合。工程保留 main 的全部 53 个对象，加入 7 个不碰撞的 FN-12 对象；18 个 Swift 源文件均进入 Sources。锁文件保留三项固定 revision，Xcode 解析成功；`originHash` 沿用 main 值，未声称由工具重新生成。编辑器以 FN-11 为基础加入更新界面层级协调及组合输入退出保护，其余 FN-11 源码／验证脚本未改。

双 Release 构建、签名检查和两组组件回归通过，证据见 [INTEGRATION.md](integration/INTEGRATION.md)。初次临时 harness 因嵌入 Sparkle 没有 Modules 导入失败，修正临时模块搜索路径后通过；产品未为测试改动。整合验证不替代真实 UI、输入法或再次安装验收。最终 PR head 推送后重新核对合并条件，再按 head 约束执行合并。
