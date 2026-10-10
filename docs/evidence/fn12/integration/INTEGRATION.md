# FN-12 与 FN-11 整合验证

2026-10-10，Dan 明确授权处理三个冲突并继续标准收尾。整合当前 main 的 FN-11 与已验收 FN-12：组合工程保留 Markdown 与 Sparkle 的 Sources、Frameworks 和包引用；锁文件保留 Sparkle 2.10.0、swift-markdown 0.9.0、swift-cmark 0.9.0；编辑器保留完整 FN-11 编辑／排版逻辑，以及 FN-12 更新窗口层级协调和退出前组合输入保护。捕获时仍处于未提交的合并工作树，具体 HEAD、MERGE_HEAD 与源码散列见 `source-state.json`。

两套 universal（arm64／x86_64）Release 构建均出现 `BUILD SUCCEEDED`，并通过构建脚本的签名与更新配置检查。Standard 保持更新关闭；LocalTrial 为 `0.1.1 (12)`，保留既有身份、手动更新配置和生产 feed。包解析结果见 `resolve.log`，应用身份、设置及可执行文件散列见 `build-results.json`。原始构建日志逐字节压缩为 `build-standard.log.gz`、`build-local-trial.log.gz`，未裁剪空白或警告。

- FN-11：使用组合源码与本次 Standard Release 的真实 Markdown／CAtomic／cmark 对象，默认组件模式完成 **2155 assertions，exit 0**；四张程序化 AppKit 位图与结果保存在 `FN11Verification/`。任务审阅 UI 未启用，未安装或启动 FinderNotes。测试生成的独立临时目录及偏好文件清理结果见 `fn11-cleanup-verification.json`，详细偏好清单亦保留。
- FN-12：从 `c2f4253` 临时恢复组件源码，编译全部产品 Swift 源码（只排除 main，保留 AppDelegate），使用 Swift 6、macOS 26 目标和本次 Release 依赖对象，完成 **100 passed / 0 failed，exit 0**。覆盖真实 AppKit modal 会话退出保护、退出防重入、草稿／组合输入早退及副作用保护、置顶协调、安装清理审计和默认目录 URL 比较回归。结果、摘要和合成安装审计回执保存在 `FN12Components/`。

两组 harness 初次编译都因 app 内嵌 Sparkle.framework 缺少 Modules 而无法导入，尚未运行测试。仅调整各自 `.build/FN12Integration` 下的临时编译脚本：FN-11 从已固定的 SPM framework 导入，FN-12 增加 Release Products framework 搜索路径，运行时均使用 app 内嵌 framework。未修改 tracked 产品源码、测试源码或验证脚本。初次失败日志与最终成功日志均保留。

构建保留已签名 Sparkle 二进制不 strip 及无 AppIntents 依赖的 metadata skipped 警告；FN-12 编译另有历史测试夹具 `AuditFixtureFileManager` 的 Sendable 警告。最终构建与两组回归没有失败项。本轮没有新增真实 UI、物理中文输入、Finder／TCC、下载安装重启或长时间使用验证；组件结果不扩展此前人工验收结论，也不改变 FN08-I07／I08 的保留边界。

本目录仅保留日志、结果、JSON 与位图证据及散列清单；不保留临时测试源码、脚本、可执行文件、dSYM、应用或故障输入夹具。JSON 回执来自独立合成组件环境，不代表本轮真实安装。`manifest.json` 记录原始路径与压缩前后散列，便于在清理 `.build` 后核对。
