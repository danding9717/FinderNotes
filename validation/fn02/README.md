# FN-02：原生服务与应用权限验证

本目录是 M0 验证应用，不是 M1 产品。任务与验收以 [FN-02 Notion 卡](https://app.notion.com/p/3e4e7607d649819694ebea91acd56b3e) 为准。

## 构建与隔离样本

需要完整 Xcode 和 `/opt/homebrew/bin/ffmpeg`（只生成 16×16 的合成 MOV）。不安装依赖、不切换全局工具链、不修改系统权限。

```sh
./scripts/verify_toolchain.sh
FN02_ROOT="$(python3 validation/fn02/prepare.py)"
./validation/fn02/build.sh "$FN02_ROOT"
```

脚本每次创建全新临时根，生成 PNG/MOV、只读与不可读副本、符号／硬链接及目录。`run.json` 被嵌入应用，限定本次 `work` 目录和两类种子 SHA-256。应用拒绝根外文件、目录、链接、替身、非匹配媒体。只读／不可读权限只设置在新合成副本上。构建目录已存在时失败，避免覆盖正在使用的应用。早期失败构建须用新根重试。

应用 bundle ID：`com.findernotes.validation.fn02`；ad hoc 签名、无 Team ID、无 sandbox/automation entitlement，不包含 Apple Events、Finder Sync、全局监听或后台服务。此配置只验证本地 AppKit 路线；不能外推正式签名、沙盒或其他 TCC 位置的行为。

## 应用进程内自测

```sh
open -n "$FN02_ROOT/FinderNotes FN02.app" --args --self-test
# 应用启动后执行并退出；不是以终端直接运行可执行文件。
tail -1 "$FN02_ROOT/events.jsonl"
python3 validation/fn02/verify.py "$FN02_ROOT" self-test
```

最后事件必须是 `self_test_complete` 且 `ok:true`，29 个 `self_test_pass`。启动命令成功不代表测试完成。只对新生成、未运行自测的根执行；自测会删除／替换专用合成副本，不能重复运行同一根。它验证同一应用进程内的真实文件操作与 Session 逻辑，不代替 Finder 服务派发或界面验收。`verify.py` 用系统 `xattr` 独立读取，并比较种子哈希、哨兵属性、正常正文及应拒绝文件未写入。

## Finder 实测安装

另建一套新样本用于界面测试，不复用被自测改变的副本。将构建出的应用放入用户的 `~/Applications/`。首次安装可执行：

```sh
# FN02_ROOT 指向新的界面测试根。
test ! -e "$HOME/Applications/FinderNotes FN02.app" || exit 1
mkdir -p "$HOME/Applications"
ditto "$FN02_ROOT/FinderNotes FN02.app" "$HOME/Applications/FinderNotes FN02.app"
```

首次打开应用以使 macOS 发现服务，正常退出，然后在 Finder 打开 `$FN02_ROOT/work`。本次实测无需手工勾选：选择文件后直接出现 **访达 → 服务 → FinderNotes FN02 验证笔记**。无选区时该项不显示。不要通过“打开方式”或终端传路径冒充系统服务测试。

可从 **访达 → 服务 → 服务设置…** 进入 **系统设置 → 键盘 → 键盘快捷键 → 服务快捷键**。本次查看到该设置页，但展开“文件和文件夹”及“文本”未找到 FN02 的独立开关；没有验证禁用／重启后重新启用，也没有配置快捷键。若当前系统没有菜单项，先核对安装路径、打开一次应用、选中单个测试副本；仍缺失时记录现象，由 Dan 决定后续，不自动重启 Finder、重置权限或关闭安全功能。

## Dan 验收步骤

1. 退出应用（未保存草稿有取消／丢弃提示）；Finder 选 `normal.png`，经上述服务菜单调用。核对完整路径、已有笔记和新进程日志。应用运行时再选 `normal.mov` 调用，验证热启动。
2. 写入合成中文／emoji 草稿。未保存时重复调用同文件：仍为同一窗口、同一进程，草稿不变。保存后必须显示“已保存并完整回读一致”。退出重开再次核对正文。
3. 多选两个副本、选择 `directory.png`、`symlink.png` 或 `hard.png` 后调用服务，应拒绝且保留已有草稿。Finder 替身需另行人工创建并验证；本轮没有实测替身。
4. 选择 `unreadable.png`，应返回 EACCES，不能加载为空笔记；选择 `readonly.png`，输入测试正文并保存，应报 EACCES，草稿仍在。点击“复制草稿”，粘贴到空白文本处核对。
5. 用新根中的 `disappear.png` 或 `replace.png` 打开会话，输入草稿，然后只对这个合成目标删除或用该根的 `replacement.png` 替换，再保存：分别报目标消失／身份变化。复制草稿核对；独立确认新替换文件没有笔记。已执行过的界面测试根不能直接重做删除场景。
6. 失败草稿复制后，“结束当前会话”需要明确丢弃。关闭窗口只是隐藏、保持本次运行的草稿；退出时对未保存文本提示。异常退出恢复不在 M0 范围。

当前验收安装位置和样本根见 [实测报告](../../docs/evidence/fn02/2026-09-24.md)。验收前避免同时运行多个同 bundle ID 构建。卸载仅退出本应用并移走本次安装的 `~/Applications/FinderNotes FN02.app`；清理仅限本次记录的临时根，勿用通配符删除其他目录。服务缓存何时移除未验证，不为清理强制重启 Finder。

## 代码与边界

- `Info.plist` 声明系统服务，`NSApplication.servicesProvider` 接收服务提供的专用 pasteboard。不会把全局剪贴板或当前 Finder 选区当作输入；全局剪贴板只用于用户点击“复制草稿”。
- `Core.swift` 保持文件描述符，通过逐层 `openat/O_NOFOLLOW` 拒绝路径链接；限制普通文件、单链接、合成种子哈希，并在保存前后核对路径身份。原始 UTF-8 写入 `com.findernotes.note.v1`，不 trim，不操作 Finder 注释。
- 单窗口、主线程串行、当前会话复用，错误不覆盖草稿。保存前检查自有属性基线；这是验证保护，不是完整 M1 冲突产品。
- fd 写入不会重定向到同名新文件，但最后检查与写入之间仍可能发生竞态：旧对象可能已被改名／删除后才写入，随后报告失败；不是文件系统事务。并发 xattr 修改也不具备原子 compare-and-swap。本轮只验证保存前已发生的替换／消失，不宣称所有竞态已解决。
- 仅临时 APFS 合成媒体；不证明受 TCC 保护目录、云盘、NAS、外置卷、正式签名／沙盒或大文件支持。没有实测要求 Finder 自动化／完全磁盘访问，不请求这些权限。

服务实现参考 [Apple Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html) 与 [NSApplication.servicesProvider](https://developer.apple.com/documentation/appkit/nsapplication/servicesprovider)。具体菜单行为以本机记录为准。
