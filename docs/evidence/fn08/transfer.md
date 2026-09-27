# FN-08 独立读取与本机传输观察

2026-09-27；macOS 26.6.2（25G83），arm64。本页只汇总本轮新建合成 PNG 的工具实测；原始 argv、退出码、输出、媒体 SHA-256 与全部 xattr 十六进制值见 `transfer.json`。既有验收资源与真实素材未参与实验。

| 本次实际操作 | 媒体 SHA-256 | 自有笔记、Finder 原生注释、无关 sentinel |
| --- | --- | --- |
| 同卷 `/bin/cp -p` | 保持 | 全部保持 |
| 同卷 `/usr/bin/ditto --rsrc --extattr` | 保持 | 全部保持 |
| 系统 ditto ZIP（`--sequesterRsrc --keepParent`）后由 ditto 解压 | 保持 | 全部保持 |
| Python 标准库 `python3 -m zipfile` 压缩／解压 | 保持 | 三项全部丢失 |

这说明媒体字节未变化也不能证明笔记随文件传输。上表只适用于记录中的同卷工具和参数，不能推及 Finder 拖拽、Archive Utility、任意 ZIP、跨卷／其他文件系统、Time Machine 或其他备份、同步盘、NAS、邮件或聊天转发；这些均未验证。源 PNG 在实验前后媒体与全部 xattr 保持不变。

传输实验资源保留在 `/private/var/folders/j_/l8s7fghx6q73l51666cwkdw00000gn/T/findernotes-fn08-transfer-goritg74`，含源文件、每种副本、压缩包和原始 `transfer.json`。该临时路径不是长期备份承诺。

独立读取方法：

```sh
python3 validation/fn08/read_note.py /absolute/path/media.png
python3 validation/fn08/read_note.py /absolute/path/media.png --export /absolute/path/new-note.md
```

属性名称为 `com.findernotes.note.v1`，内容是原始 UTF-8 正文，无 JSON 包装或额外头部。工具 JSON 输出分别标明 `missing`（属性不存在）、`empty`（存在但零字节）、`present`、`invalid_utf8` 或 `read_error`。读取不会修改媒体，也不读取 Finder 原生注释或恢复目录。读取前会规范化源与目标路径（包括 `/var` 与 `/private/var`、符号链接别名），同源目标直接拒绝且不读取。导出先在同目录独占创建临时文件，完整写入、fsync 与逐字节回读，再以 macOS `renamex_np(..., RENAME_EXCL)` 发布，并持有文件描述符核对最终路径身份与正文。目标已存在时失败；缺失、无效 UTF-8 或读取失败时拒绝导出。发布后删除／替换导致最终状态不能确认时返回 `publication_unconfirmed`，保留独立诊断正文；不会删除并发替换文件。失败临时文件也保留，路径见 JSON。确认仅限检查时刻，不能阻止后续外部修改。Markdown 为独立正文快照，不构成同步、自动备份或第二套笔记库。

`independent-read.json` 保留修正前 9 个独立 CLI 调用的原始记录，不能证明最终发布竞态保护。最终辅助工具证据以 `independent-read-final.json` 和 `read-note-regressions.log` 为准：`validation/fn08/test_read_note.py` 的 11 项隔离回归覆盖正常／空正文、缺失属性、不覆盖、源目标同路径与两种别名、部分写入、写入失败，以及发布后删除／替换故障注入；全部通过，全部新建源样本媒体与所有属性保持。故障注入属于辅助工具确定性测试，不能替代产品 UI 或 TCC 实测。最终实验根和失败保留路径均记录在该 JSON 中；没有修改 Finder/UI 样本。不存在文件错误不是权限拒绝或 TCC 测试；独立读取也不是原子 CAS。

`fixture-path.txt` 指向本轮 Finder/UI 合成样本根；`fixtures-baseline.json` 是调用 app 之前的原始基线。`fixture-media.json` 证明音轨与视频轨各为 30 秒（合成正弦波编码前乘 0.05 音量系数），不能据此认定声音可闻或收起后停止。该根下 `evidence/independent-read` 保留独立读取样本、导出与原始记录。
