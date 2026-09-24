# FN-04 独立 UI 验收样本

这些脚本只建立新的临时合成 PNG/MOV 副本，用于当前产品应用的真实 Finder 服务和编辑窗口验收。它们不会安装、启动、退出或操作应用，不读取真实素材，不复用 FN-01/FN-02 样本。需要 macOS、Python 3 和本机已有 ffmpeg；不安装依赖、不申请系统权限。

```sh
FN04_ROOT="$(python3 -B validation/fn04/prepare.py)"
python3 -B validation/fn04/verify.py "$FN04_ROOT"
```

`prepare.py` 每次用 `mkdtemp` 新建 `findernotes-fn04-*` 根；所有文件独占创建，ffmpeg 使用 `-n`，不会覆盖已有目录或文件。stdout 只输出新根的绝对路径。`work` 内包含：

| 文件 | 自有笔记 | 用途 |
| --- | --- | --- |
| `normal.png` | 中文、emoji、换行和首尾空白 | PNG 冷启动、编辑及重复服务调用 |
| `normal.mov` | 中文、emoji、换行 | 真实 16×16 MPEG-4/MOV 热启动 |
| `empty.png` | 存在，零字节 | 显示已有空笔记 |
| `missing.png` | 属性不存在 | 显示尚无笔记 |
| `invalid.png` | 原始 `ff` 字节 | UTF-8 读取失败，保留原会话 |
| `unreadable.png` | 中文正文，mode `000` | 读取拒绝，不能误报空笔记 |

每个文件都有独立 sentinel 属性和二进制 plist 格式的原生 Finder 注释。写入这些字节不表示已经验证 Finder 正确显示注释。`before.json` 保存媒体 SHA-256、所有扩展属性的完整十六进制字节、文件身份及预期 mode；不可读样本的内容在设置 mode `000` 前记录，记录中明确标注。

`verify.py` 通过 macOS libc 的 fd xattr 接口读取，兼容没有 `os.getxattr` 的系统 Python。它校验生成标记和清单，比较媒体及所有属性，拒绝被替换或链接化的样本。它不写样本、不改变权限，只向 stdout 输出 JSON；有差异/错误退出 `1`。

对于保持 mode `000` 的 `unreadable.png`，验证器只核对身份和权限，明确输出 `skipped-content`，不自动 chmod。此时整体结果为 `status: partial`、`complete: false`，即使其余 5 个文件全部一致也不能宣称全部 6 个内容通过。`comparedFilesMatch: true` 仅表示已比较的项目无差异，退出 `0` 不代表完整验收。

Finder 实测前保存新根路径；实测后运行同一根的 `verify.py`，保留真实结果。可将 `before.json`、验证器 stdout、实测说明和截图持久复制到 `docs/evidence/fn04/` 的本次独立目录；保留原始 root/runID，不把复制证据误当作新样本。复制文件时应使用独占创建或另建证据目录，避免覆盖历史证据。

本目录只提供样本和独立只读核对，不证明服务派发、中文输入法组合态、查找、撤销重做、窗口缩放或外观已经实测。仅清理本次记录的确切新临时根，不用通配符删除其他目录。
