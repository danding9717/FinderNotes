# FinderNotes 0.1.4（15）发布归档

源码提交：`72e49b41c71aa3922a6a7c95f7ee1e6fb2b1ac41`。与过渡版 14 使用相同实现，仅递增版本，供 Dan 验证从新更新源继续安装。

复现构建：

```sh
FINDERNOTES_BUILD_PROFILE=local-trial FINDERNOTES_DERIVED_DATA="$PWD/.build/release15" ./scripts/build_app.sh -onlyUsePackageVersionsFromResolvedFile
```

使用固定提交中的准备脚本、本目录 release-notes.txt 及原钥匙串账号签名。构建、ZIP 往返、严格代码签名与 Ed25519 独立验签通过，arm64/x86_64 双架构。标准 profile 在过渡版 14 的相同实现上验证通过；Intel 运行、真实 13→14→15 安装与新源检查仍待人工验证。构建及 ZIP 时间戳不保证逐字节可复现，以已发布包的 SHA-256 为准。

Release 只上传 ZIP 和 SHA256SUMS。完整迁移操作与旧仓删除条件见 [更新手册](../../UPDATES.md)。
