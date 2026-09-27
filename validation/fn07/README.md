# FN-07 隔离验证与 Dan 验收步骤

本目录只生成并操作本轮独立合成样本。不会读取真实素材或复用 FN-04／FN-05／FN-06 验收目录。以下步骤是验收方法，不表示已经执行或通过；实际命令、输出、截图与失败项须另行留证。

## 构建身份与恢复目录

在本工作树使用 `FINDERNOTES_BUILD_PROFILE=fn07 scripts/test_app.sh` 运行确定性测试，使用 `FINDERNOTES_BUILD_PROFILE=fn07 scripts/build_app.sh` 生成 Release 验收应用。Debug 与 Release 的 bundle ID 分别为 `com.findernotes.FinderNotes.FN07Tests` 与 `com.findernotes.FinderNotes.FN07Validation`。Release 的 Finder 服务是“FinderNotes FN07 验收编辑笔记”，服务端口为 `FinderNotesFN07Validation`；Debug 不发布 Finder 服务。产物位于本工作树 `.build/DerivedData/Build/Products/`。

恢复目录按当前应用的 bundle ID 隔离：

```text
~/Library/Application Support/<bundle ID>/DraftRecovery/v1/
```

因此 FN07 Release 的目录是 `~/Library/Application Support/com.findernotes.FinderNotes.FN07Validation/DraftRecovery/v1/`。每个编辑会话使用一个 UUID 命名的 `.json` 恢复文件，格式版本为 1。目录权限为 0700、文件权限为 0600；恢复文件包含未保存草稿、目标身份与打开时的自有 xattr 基线，属于本机明文恢复数据，不能写入普通日志或上传。仅自有 `com.findernotes.note.v1` 是正式笔记来源。

草稿通过临时文件与原子替换写入；只承诺恢复已落盘的草稿，不承诺最后尚未落盘的击键，也不承诺突然断电的完整持久性。保存成功或明确放弃后清理对应恢复文件；导出本地草稿、取消对话框或导出失败不等于放弃。恢复时校验目标身份与原始基线；目标消失、同名替换、身份无法确认时保留导出路径，不自动写回。xattr 的“检查后写入”不是原子 CAS。

## 全新合成样本与只读证据

```sh
python3 -B validation/fn07/prepare.py
```

脚本每次输出一个全新的 `findernotes-fn07-…` 临时根，只使用生成的 PNG 像素与 ffmpeg 合成视频／音轨。`work/` 包括 `recovery.png`、`conflict.png`、`deletion.png`、`unrelated.png`、`replace.png`、`moved.png`、`empty.png`、`missing.png`、`copy-source.png`、`copy.png`、`readonly.png`、`portrait.png` 和 30 秒的 `audio.mov`。`copy.png` 的媒体和 xattr 字节与 `copy-source.png` 相同，但文件身份独立；`readonly.png` 为 0444。`before.json` 保存原始身份、权限、媒体 SHA-256 与全部 xattr 字节；`.fn07-owned.json` 标识本轮所有权，`archive/` 保留故意移走或替换的原件。

将本次输出填写到下方 `fixture_root`，不使用历史路径：

```sh
fixture_root=/absolute/path/to/findernotes-fn07-NEW
python3 -B validation/fn07/verify.py "$fixture_root" > "$fixture_root/evidence/before-check.json"
python3 -B validation/fn07/verify.py "$fixture_root" --file empty.png --expect-note empty.png=
python3 -B validation/fn07/verify.py "$fixture_root" --file missing.png --expect-note missing.png=missing
```

`verify.py` 不修改样本。`--file` 可重复，`--expect-note NAME=HEX` 可重复；正文预期使用 UTF-8 原始十六进制，`NAME=` 表示已存在的空属性，`NAME=missing` 表示属性缺失。未指定预期时与原始笔记比较。输出包括所有 xattr 的原始十六进制，只可用于这些合成样本；读取失败单独报错，不折叠为空正文。独立哈希／xattr 回读只证明当次观察，不是跨文件系统／云同步或并发原子性证明。

故意替换身份、移动文件或修改无关属性后，对原始 `before.json` 的全量检查会返回失败；这用于标出故意变化，不能直接写成应用回归。保留该输出，并使用 mutation 记录中的 `before`／`after` 与当前 `actual` 检查应用是否额外改变了文件。普通正文保存可用精确 `--expect-note` 核验，要求身份、媒体、权限和无关属性仍全部一致。

## 受限的外部变更工具

以下命令仅接受当前根原始清单内、身份及媒体内容仍匹配的普通文件，拒绝其他文件及已替换目标。每次会在 `evidence/` 保存独立 mutation JSON；正文默认是脚本内的合成文本。`replace` 保持媒体和全部 xattr 字节相同，故意改变身份并保留原件；`move` 将原件移入 `archive/`，不删除它。

```sh
python3 -B validation/fn07/mutate.py "$fixture_root" conflict.png note
python3 -B validation/fn07/mutate.py "$fixture_root" deletion.png delete-note
python3 -B validation/fn07/mutate.py "$fixture_root" empty.png note --hex ''
python3 -B validation/fn07/mutate.py "$fixture_root" unrelated.png unrelated
python3 -B validation/fn07/mutate.py "$fixture_root" replace.png replace
python3 -B validation/fn07/mutate.py "$fixture_root" moved.png move
```

这些是顺序操作的测试工具，identity check 与变更之间仍存在时间窗口；不能用于真实素材或用作应用安全写入 API。

## 三类证据分开记录

1. **确定性测试：** 使用 FN07 Debug 身份，保存 xcodebuild 完整结果、xcresult 路径、测试数量、失败项和环境。重点包括原子草稿文件写入／读取／清理、损坏或不支持版本、保存失败与恢复写入失败、missing／empty／read error、身份不符／复制品、外部正文变化以及组合态与定时器。代码测试不等于 Finder／真实中文输入法验收。
2. **真实文件集成：** 每组使用新合成根，保留 `before.json`、mutation、只读核验输出、导出的两方 Markdown 及恢复文件状态。使用本机 APFS 普通文件验证读写、外部 xattr 变更、同名替换、移动、复制品及异常结束重启。0444 测试只证明 Unix 文件权限失败，不等于 TCC 拒绝。
3. **Finder／UI：** 从 Finder 对本轮 `work/` 中单文件调用 FN07 服务；记录实际页面、按钮、取消路径、保存后重新打开结果及截图。中文候选组合必须使用真实输入法，粘贴中文和程序 marked text 不能替代。

### 真实子进程 SIGKILL 存储集成

`run-crash-probe.py` 使用 `swiftc -O`、Swift 6、不定义 `DEBUG`，将生产 `NoteReader.swift`、`DraftRecoveryStore.swift` 与 `crash_probe.swift` 编译为独立命令行进程，不经过 xcodebuild 或应用 UI。它新建合成 PNG 与独立恢复目录，待子进程 `put` 成功返回并报告 ready 后，仅 SIGKILL 自己 spawn 的活跃 PID，并记录实际 `-9` 退出。接着三次启动新的只读 inspector：原身份／原基线匹配、外部正文改变后基线不匹配、同名替换且媒体／原始 xattr 相同但身份不匹配。每次均验证已落盘草稿精确字节以及目标和恢复文件未被 inspector 改动。

```sh
python3 -B validation/fn07/run-crash-probe.py
# 保留既有证据，后续重跑必须指定一个尚不存在的输出路径。
python3 -B validation/fn07/run-crash-probe.py --output /absolute/new/evidence/process-crash-rerun.json
```

首次默认报告为 `docs/evidence/fn07/process-crash.json`，报告包含命令、编译输出、生产源文件 SHA-256、退出信号和三个 inspector 的原始 JSON；正文不进入报告，只保存哈希、字节长度和布尔值。独立临时根及其中恢复 JSON 保留以便复核。这证明真实进程中已发布恢复记录可在 SIGKILL 后读取，以及生产 reader 的身份／基线校验结果；不证明 App/Finder 恢复交互、真实输入法、尚未落盘击键或突然断电。生产代码变化后应以新的源文件哈希重新执行并保留原报告。

## Dan 的主要验收路径

- **高级选项与底部布局：** 底部只保留一行“保存、复制、导出、高级选项”，“复制”仍复制当前草稿，“导出”仍打开 Markdown 导出流程。点击原生“高级选项”下拉菜单，确认两项为“核对外部版本…”和“恢复草稿…”（有记录时含数量）；选择后按钮仍显示“高级选项”。在没有打开文件的空窗口中，外部核对禁用、恢复可用，并可打开恢复列表或无记录提示。打开合成文件后核对可用；读取、保存、导出与确认期间相关入口禁用，取消后恢复正确状态。将窗口缩到最小 500 点宽，展开／收起预览时所有底部操作完整显示且不重叠；冲突／暂停提示留在状态区，指向“高级选项 → 核对外部版本”。UI 被锁屏阻挡时单独记未验证，不用 AppKit 测试替代点击或目视检查。
- **预览图标与输入状态：** 左侧预览区上方靠正文一侧应显示无文字的 `sidebar.left` 图标（16 点图形、28×28 点点击区域），置于独立 32 点头部，不覆盖 Quick Look 或正文。悬停提示及无障碍名称随状态显示“收起预览”或“展开预览”。点击收起后左侧保留 32 点窄栏与图标，正文扩宽，再次点击可重新展开；在最小 500 点宽和空窗口中均检查入口可见、可点且不重叠。带选区、撤销记录及长文滚动位置切换预览，确认草稿和输入状态保留；预览获得焦点后收起，应可继续在正文输入。真实中文组合态与合成视频播放中的收起停止、声音须分别实测，未实际观察的边界继续记未验证，不能由程序化测试或历史任务状态替代。

- **外部修改与两方保留：** 打开 `conflict.png`，运行其 `note` mutation，再输入本地合成草稿；触发手动保存或等待约 1 秒自动保存，确认暂停且未静默覆盖。点“高级选项 → 核对外部版本…”后，“继续编辑”应保留草稿；“仅导出本地草稿…”应保留会话；“导出草稿并载入外部版…”应先成功导出本地，才载入外部。取消导出或导出失败不能替换草稿。另用新根验证“备份外部版并覆盖…”先导出外部，再经“明确覆盖”确认写入本地；确认前双方都保留。
- **删除／空正文／无关属性：** 分别使用 `deletion.png` 的 `delete-note`、`empty.png` 和 `missing.png` 验证属性删除、空正文及缺失的区别。只对 `unrelated.png` 执行 `unrelated`，确认不因哨兵 xattr 变化直接判成正文冲突。核验时以 mutation 的外部修改为预期，并确认应用未再改哨兵或 Finder 原生注释。
- **异常退出恢复：** 使用 `readonly.png` 使正式保存失败并暂停，输入合成草稿；先确认 FN07 专属恢复目录内已出现对应落盘记录，再仅对路径匹配本工作树 FN07 验收产物的进程执行强制结束。不要结束其他 FinderNotes 实例或 Finder。重启同一 FN07 应用，点“高级选项 → 恢复草稿…”并选“恢复所选草稿”，确认内容来自已落盘记录，恢复后自动保存仍暂停。原目标仍存在且基线一致时，在恢复写入权限后手动保存；确认只更新自有 xattr，并清理对应恢复记录。权限恢复仅操作本轮 `readonly.png`：`chmod 644 "$fixture_root/work/readonly.png"`，同时记录这是预期权限变化。
- **身份与基线：** 在保有已落盘草稿并结束 FN07 进程后，分别执行 `replace.png replace` 或 `moved.png move`，重启并恢复对应草稿。不得自动写回同名替换文件；目标消失或身份无法确认时只能保留／导出。用 `copy-source.png` 制造草稿后仅打开 `copy.png`，即使媒体和正文相同也不得给复制品套用原件草稿。另用新根在异常结束后外部改变原目标正文，恢复应保留本地和外部内容并进入冲突处理。
- **与原编辑流程集成：** 分别观察手动保存、停止输入约 1 秒自动保存、保存失败后的暂停、真实中文组合态、关闭／切换与取消操作。未保存草稿不得被取消路径丢弃；“明确放弃”才清理对应恢复文件。用底部“导出”验证可导出当前本地草稿的 Markdown 快照。

声音、播放中收起停止、长文滚动和真实中文输入法若本轮未新增实测，应继续列为未验证；不能因 FN-06 Done 或已合并改写成通过。保留新建样本与原始证据给 Dan 复验，不清理既有验收资源；清理本轮资源前核对完整路径和 `.fn07-owned.json`。
