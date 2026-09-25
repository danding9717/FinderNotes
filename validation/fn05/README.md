# FN-05 隔离样本

在 FN-05 工作树执行 `python3 -B validation/fn05/prepare.py`。命令新建带唯一 runID 的临时目录，输出其绝对路径；不读取或覆盖已有素材。`work/` 内有真实合成 PNG、1 秒 MOV、空属性、缺失属性、冲突样本及由 `cp -p` 创建的独立图片副本。`before.json` 记录每个文件的媒体 SHA-256、身份和所有 xattr 原始十六进制字节；Finder 原生注释属性是构造的 plist，仅用于字节保护核对。

先运行 `python3 -B validation/fn05/verify.py <本次输出目录>`，确认样本与基线一致。保存测试后用 `--expect-note 文件名=正文UTF8十六进制` 指定预期变更；如果预期属性缺失则写 `文件名=missing`。未指定的文件仍按原始基线核对。核验器只读，不自动改样本或笔记；失败时检查输出中的媒体、身份、自有笔记和无关 xattr 四项。导出的 Markdown 另用独立字节比较核对。

只把这次新生成的样本用于 FN-05 应用及 Finder 服务验收。保留样本和 `before.json` 供 Dan 复查；清理必须先确认路径及归属。不要操作 FN-04 验收应用、旧 Orbit 或真实素材。
