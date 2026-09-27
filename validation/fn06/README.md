# FN-06 隔离验收样本

运行 `python3 -B validation/fn06/prepare.py`，记录输出的唯一临时根。所有媒体由脚本合成，不读取真实素材；`before.json` 保存身份、媒体 SHA-256、权限及完整 xattr 原始字节。原生 Finder 注释是构造的 plist，只用来验证应用不改动这些字节。

样本包括 640×360 横图、240×480 竖图、带低音量音轨的 30 秒 MOV、损坏 PNG/MOV、空属性、缺失属性、外部冲突、只读文件及独立副本。`readonly.png` 为 0444，其他测试文件可写。损坏媒体只用于验证预览降级，不能当成实际格式支持证据。

```sh
python3 -B validation/fn06/verify.py /absolute/path/to/findernotes-fn06-ROOT
python3 -B validation/fn06/verify.py /absolute/path/to/findernotes-fn06-ROOT --expect-note wide.png=正文的UTF8十六进制
```

`--expect-note` 可以重复，空正文写 `empty.png=`，属性缺失写 `missing.png=missing`。未指定的文件按原始笔记核对。核验器不修改任何文件，显式核对读取成功、身份、权限、媒体、自有正文及所有无关属性；读取失败会报告失败，不会转为空值。需要故意修改无关属性的测试应使用额外独立副本并另存前后证据，不能把意外变化混进普通验收的预期。

用 Release 服务“FinderNotes FN06 验收编辑笔记”打开 `work/` 中的单文件。检查横竖比例、视频打开无自动播放、点击播放后收起停止、重新展开不自动播放；尝试损坏媒体时继续写字、保存和导出。正文停止输入约 1 秒后独立回读，并关闭应用再从 Finder 重开。中文输入须使用真实输入法保留候选组合超过 1 秒，确认尚未提交的文字未写入；粘贴中文和程序 marked text 不替代此项。

在独立副本上验证外部正文修改后的暂停、权限恢复后的手动保存、同名替换保护、副本独立及关闭／切换倒计时取消。自动测试、真实文件集成、Finder 服务与视觉／声音观察分别记录。留存样本给 Dan 复验；清理前核对 `.fn06-owned.json` 和完整路径，只清理本轮创建的资源。
