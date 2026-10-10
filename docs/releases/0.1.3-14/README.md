# FinderNotes 0.1.3（14）发布归档

源码提交：`7086b56ff40684031058001158a333a10bffa9e9`。本构建将生产更新源改为同仓库 `updates` 分支；旧更新源仍保留到真实升级验收后。

复现构建（需要完整 Xcode，使用该提交的 Package.resolved）：

```sh
FINDERNOTES_BUILD_PROFILE=local-trial FINDERNOTES_DERIVED_DATA="$PWD/.build/release14" ./scripts/build_app.sh -onlyUsePackageVersionsFromResolvedFile
```

随后用该提交的 `scripts/prepare_update.py`、本目录 `release-notes.txt` 和原有钥匙串账号准备签名包。构建不安装；包签名的私钥不在仓库中。ad hoc 构建与 ZIP 时间戳不保证重复构建逐字节相同，以已发布包的 SHA-256 为准。

Release 只上传 ZIP 和 SHA256SUMS；appcast 与本目录资料是开发归档，不作为附件。通用架构构建、严格代码签名、ZIP 往返、应用内公钥独立验签通过；真实 13→14→15 安装与重启仍待 Dan 验证，Intel 运行未测。
