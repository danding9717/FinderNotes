# FinderNotes 0.1.5（16）发布归档

源码提交：`981b268f003b66391547107dbcd395fcfde8a122`，tag `v0.1.5` 指向该提交。滚动修复经 PR #17 合并；版本号准备经 PR #18 合并。

复现构建：

```sh
FINDERNOTES_BUILD_PROFILE=local-trial \
FINDERNOTES_DERIVED_DATA="$PWD/.build/DerivedData-release-0.1.5-16" \
  ./scripts/build_app.sh ARCHS='arm64 x86_64'
```

使用固定提交中的准备脚本、`release-notes.txt` 和原 Sparkle 更新签名账号。Xcode 27.0 在 Apple Silicon 主机上构建 universal 包（arm64/x86_64）；应用身份、LocalTrial Finder 服务、生产 feed 和更新公钥保持不变。构建脚本的严格代码签名检查、ZIP 往返和 EdDSA 更新签名验签通过。匿名下载的 ZIP 与本地 SHA-256、长度一致；解包后的身份、版本、架构和严格代码签名复核通过。

自动化测试未运行；FinderNotes 内实际编辑时的滚动验收，以及旧版 0.1.4 → 0.1.5 的应用内下载安装与重启待 Dan 验证。发布包采用 ad hoc 签名，未进行 Apple 公证。Release 附件仅有 ZIP 与 `SHA256SUMS`；公开 feed 更新提交为 `188a579c33c7a1c949a2846883994a533afbe2a6`。
