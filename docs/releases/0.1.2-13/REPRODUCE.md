# 复现 FinderNotes 0.1.2（13）

在私有源码仓库中使用 Git 提交 fb06e62d9903ae2a336dcd8df1cdc99f9295ea79。创建空发布目录，将附件 build-release.sh 与 Info-Release.plist 放入其中。运行 `git archive fb06e62d9903ae2a336dcd8df1cdc99f9295ea79 | tar -x -C <发布目录>/source`（先创建 source 目录），然后 `zsh <发布目录>/build-release.sh`。

Info-Release.plist 来源为该提交的 FinderNotes/Info-LocalTrial.plist，仅将 CFBundleShortVersionString 改为 0.1.2、CFBundleVersion 改为 13。build-release.sh 使用原构建脚本，显式传 LocalTrial 身份和该 plist；使用锁定的依赖。默认 tag 源码仍是 0.1.1（12）。

构建后需独立使用 scripts/install_local_trial.py 的 validate 核验 LocalTrial 名称、身份、服务和严格签名，再核验 feed、公钥、四项自动更新/画像开关关闭、解压前验签开启及 universal 架构。发布前使用原 prepare_update.py 和固定 Sparkle 2.10.0 sign_update，以已有钥匙串 account 签名，不导出或重建私钥。

生产 appcast 使用内嵌 description HTML，移除 releaseNotesLink，fullReleaseNotesLink 指向公开 Release 网页。这样说明展示不依赖 GitHub HTML 附件的 MIME 类型。ZIP 字节与签名不因该元数据调整而改变。
