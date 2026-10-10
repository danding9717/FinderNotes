# FinderNotes 0.1.2（13）发布开发材料归档

本目录保存原私有 Release v0.1.2 的构建复现材料、发布验证记录及 HTML 更新说明。文件从 GitHub Release 下载后逐项按原 asset SHA-256 和字节数验证，保留原始内容；对应清单见 archive-manifest.json。公开更新仓的 HTML 附件与这里的 HTML 文件字节相同。

- 安装包与 SHA256SUMS 继续保留在私有 v0.1.2 和公开 v0.1.2-13 Release。
- 原代码与版本来源见 source-provenance.json，构建复现见 REPRODUCE.md、Info-Release.plist 和 build-release.sh。
- download-verification.json 与 production-ui-verification.json 记录发布时的实际验证范围。
- FinderNotes-0.1.2-13.html 保存更新说明；当前生产 appcast 已内嵌说明，不引用该 HTML 附件。

此次整理仅移动 Release 附件，不改产品源码、main、版本标签、ZIP、校验文件或生产 appcast。归档位于独立 chore/release-archives 分支，Release 正文使用固定提交链接。

后续发布注意：现有 prepare_update.py 默认生成外部 releaseNotesLink。若继续保持仅两个附件，发布 feed 时须使用内嵌 HTML description，并移除指向 HTML 附件的 releaseNotesLink；不能用默认生成文件覆盖生产 feed。
