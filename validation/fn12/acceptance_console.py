#!/usr/bin/env python3
"""Loopback-only controls for the isolated FN12 human acceptance environment.

This serves Sparkle fixtures; it never launches or installs applications, reads
user notes, changes the production feed, or resets an in-flight update.
"""
import argparse
import datetime
import hashlib
import html
import json
import os
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from fixture_server import CASES, appcast
from prepare_review import VARIANTS

LABELS = {
    "update": "发现新版 13／完整升级演练", "latest": "已是最新版",
    "local-ahead": "本地版本领先", "404": "检查失败：404",
    "invalid": "检查失败：无效元数据", "timeout": "检查失败：超时（约 60 秒）",
    "bad-signature": "下载后拒绝：错误签名", "corrupt": "下载后拒绝：损坏包",
    "slow-download": "慢下载／中途取消",
}


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    variant = VARIANTS["acceptance"]
    root = Path(__file__).resolve().parents[2] / ".build" / variant["directory"]
    if root.is_symlink() or root.resolve() != root:
        raise SystemExit("Acceptance root must be an ordinary worktree directory.")
    manifest = json.loads((root / "manifest.json").read_text())
    installed = root / "Installed" / variant["appName"]
    if (manifest["identity"] != variant["identity"] or manifest["port"] != variant["port"]
            or manifest["installedApp"] != str(installed)):
        raise SystemExit("Acceptance manifest identity, path or port differs.")
    port = manifest["port"]
    hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    origins = {f"http://{host}" for host in hosts}
    token = secrets.token_urlsafe(32)
    lock = threading.RLock()
    events = []
    evidence = root / "evidence"
    evidence.mkdir(mode=0o700, exist_ok=True)
    watcher = None
    watch_deadline = 0

    def start_watch():
        nonlocal watcher, watch_deadline
        if watcher is not None and watcher.poll() is None:
            return
        logfile = evidence / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3) + "-cleanup-watch.log")
        with logfile.open("x") as stream:
            logfile.chmod(0o600)
            watcher = subprocess.Popen([sys.executable, "-B", str(Path(__file__).with_name("verify_acceptance.py")),
                                        "--watch-cleanup", "--watch-seconds", "120"], stdout=stream, stderr=subprocess.STDOUT)
        watch_deadline = time.time() + 120
        event("cleanup-watch-started", pid=watcher.pid, seconds=120)

    def installed_build():
        with (installed / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != variant["identity"]:
            raise ValueError("Installed acceptance identity changed")
        return info["CFBundleVersion"]

    def current_case():
        value = json.loads((root / "state.json").read_text())["case"]
        if value not in CASES:
            raise ValueError("Unknown fixture case")
        return value

    def event(kind, **data):
        row = {"time": now(), "kind": kind, **data}
        with lock:
            events.append(row)
            del events[:-16]
            with (evidence / "console-events.jsonl").open("a") as stream:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")

    def pending_download():
        return (root / "valid-download-served.json").exists() and installed_build() == "12"

    def page():
        case, build = current_case(), installed_build()
        watching = watcher is not None and watcher.poll() is None
        watch_status = f"清理观察正在运行，最多还剩 {max(0, int(watch_deadline-time.time()))} 秒；重复点击不会延长。" if watching else "当前没有运行中的清理观察；安装前可开始新的 2 分钟观察。"
        buttons = []
        for key in CASES:
            disabled = " disabled" if pending_download() and key != "update" else ""
            selected = " selected" if key == case else ""
            buttons.append(f'<form method="post" action="/control"><input type="hidden" name="token" value="{token}">'
                           f'<input type="hidden" name="action" value="case"><input type="hidden" name="case" value="{key}">'
                           f'<button class="{selected}"{disabled}>{html.escape(LABELS[key])}</button></form>')
        rows = "".join(f'<li><time>{html.escape(row["time"])}</time> {html.escape(json.dumps({k:v for k,v in row.items() if k!="time"},ensure_ascii=False))}</li>' for row in events[-10:]) or "<li>尚无测试请求</li>"
        frozen = "有效包已完整传输；请完成本轮安装。构建 13 到位后场景自动解锁。" if pending_download() else "先测失败与取消，最后下载有效新版。"
        permission = "".join(f'<form method="post" action="/control"><input type="hidden" name="token" value="{token}">'
                             f'<input type="hidden" name="action" value="draft"><input type="hidden" name="mode" value="{mode}">'
                             f'<button>{label}</button></form>' for mode,label in [("readonly","只读草稿测试图：禁止保存"),("writable","只读草稿测试图：允许保存")])
        verification_buttons = "".join(f'<form method="post" action="/control"><input type="hidden" name="token" value="{token}">'
                                      f'<input type="hidden" name="action" value="{action}"><button{" disabled" if action == "watch" and watching else ""}>{label}</button></form>'
                                      for action,label in [("baseline","安装前：记录已保存正文基线并观察清理"),("verify","重启后：独立核验正文、版本与进程"),("watch","开始观察清理（最多 2 分钟）")])
        summary_path = evidence / "console-verification-summary.json"
        summary = html.escape(json.dumps(json.loads(summary_path.read_text()), ensure_ascii=False)) if summary_path.exists() else "尚未记录安装前基线或执行重启后核验。"
        return f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FinderNotes 更新验收控制台</title><style>
body{{font:16px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;background:#f4f6fa;color:#192333;margin:0}}main{{max-width:960px;margin:32px auto;padding:0 24px}}h1{{font-size:30px;margin-bottom:4px}}h2{{font-size:21px}}section{{background:white;border:1px solid #dde3ed;border-radius:16px;padding:22px;margin:18px 0}}.muted,time{{color:#58677c}}.state{{font-size:19px;font-weight:600}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}}button{{font:inherit;cursor:pointer;border:1px solid #ccd5e3;border-radius:10px;padding:12px;background:#fff;width:100%;text-align:left}}button:hover{{background:#edf4ff}}button.selected{{background:#0969da;color:white;border-color:#0969da}}button:disabled{{opacity:.45;cursor:default}}code{{overflow-wrap:anywhere;background:#f0f3f8;padding:2px 5px;border-radius:4px}}a{{color:#0969da}}li{{margin:8px 0}}.logs{{font-size:13px;overflow-wrap:anywhere}}.warning{{border-left:4px solid #d09820;padding-left:14px}}strong{{font-weight:650}}</style>
<main><h1>FinderNotes 更新验收</h1><p class="muted">仅这台 Mac · 独立测试应用 · 个人版与生产更新源保持原样</p>
<section><div class="state">当前安装：0.1.{"1" if build=="12" else "2"}（{html.escape(build)}）</div>
<p>下一次更新检查场景：<strong>{html.escape(LABELS[case])}</strong> · <a href="/">刷新状态</a></p>
<p class="warning">{frozen} 场景切换只影响之后的网络请求；已有下载或待安装更新会被 Sparkle 优先恢复。下方出现对应的新 <code>appcast</code> 请求，才证明检查了该场景。</p></section>
<section><h2>按顺序验收</h2><ol>
<li>切到<strong>已是最新版</strong>，在“FinderNotes 更新验收 → 检查更新…”确认原生提示；关闭提示后可测 404、元数据错误、超时和本地领先。</li>
<li>切到<strong>慢下载</strong>，在应用点击下载，进度出现后取消；错误签名与损坏包应下载后报错、仍为构建 12。每次先关闭上次提示，再切场景并重新检查。</li>
<li>最后切到<strong>发现新版 13</strong>，检查并下载。更新说明出现后，在下载／安装就绪时确认检查菜单不会重复发起检查。</li>
<li>用 Finder 的独立服务<strong>FN12 验收更新（隔离副本）</strong>打开测试图。只读草稿图可稳定产生未保存内容；点击安装后选“返回编辑”，确认正文与进程保留。随后在本页允许保存，回到应用完成中文输入并保存。</li>
<li>保存后，在本页点击<strong>安装前：记录已保存正文基线并观察清理</strong>，然后在 2 分钟内重新“检查更新…”打开待安装窗口，点击<strong>安装并重启</strong>。关于窗口应变为 <strong>0.1.2（13）</strong>。不要在记录基线后继续修改正文；如需修改，先告诉 Codex 保留并重建本轮基线。</li>
<li>重启后点击本页<strong>独立核验</strong>，确认正文 matches、构建 13、PID 已变化；再切到最新版检查。清理观察结果另保留证据，未看到旧 inode 时仍为 unknown，不能仅凭新版启动算清理通过。</li>
</ol><p class="warning">点击安装后取消退出，Sparkle 保留同一次手动请求；之后正常退出也可能继续安装。不要靠退出重启、删缓存或覆盖降级重置测试。跨更新窗口的原中文候选接续仍是观察项，不能默认算通过。</p></section>
<section><h2>切换下一次检查</h2><div class="grid">{"".join(buttons)}</div><p>断网用控制台外停止此本机服务模拟；服务器恢复后重试。真实生产 HTTPS、Gatekeeper 和安装授权取消另行验收。</p></section>
<section><h2>草稿保护用测试图</h2><p>文件夹：<code>{html.escape(str(root/"media"))}</code>。只在这两份合成图上输入和导出，不使用真实笔记文件。</p><div class="grid">{permission}</div><p class="muted">这些按钮只更改本轮“只读草稿测试.png”的保存权限，不保存正文。允许保存后还需回应用点击保存。</p></section>
<section><h2>安装前后独立核验</h2><div class="grid">{verification_buttons}</div><p>{watch_status} 刷新查看剩余时间；若时间不足，等结束后再开始。</p><p class="logs">{summary}</p><p class="muted">基线只记录已落盘正文的长度和 SHA256，不能证明未保存的击键已保存。观察只读本次精确缓存路径，2 分钟到期即停止。核验不会保存笔记、退出或安装应用，也不替代 Dan 的验收。</p></section>
<section><h2>最近请求与场景</h2><ul class="logs">{rows}</ul><p class="muted">刷新本页查看新记录。这里只证明实际请求与传输，安装、中文输入和草稿结果由人工操作与独立核验确认。</p></section>
</main></html>'''.encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *values):
            # Mutation tokens are in POST bodies and never logged.
            with lock:
                with (root / "requests.log").open("a") as stream:
                    stream.write(f"{now()} {self.address_string()} {format % values}\n")

        def local_host(self):
            return self.headers.get("Host") in hosts

        def send_bytes(self, status, body, content_type="text/plain; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if not self.local_host() or self.headers.get("Origin") not in origins:
                self.send_bytes(403, b"Local origin required"); return
            if self.path != "/control":
                self.send_bytes(404, b"Unknown action"); return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 2048:
                    raise ValueError("Invalid request length")
                data = parse_qs(self.rfile.read(length).decode("utf-8"), strict_parsing=True)
                if not secrets.compare_digest(data.get("token", [""])[0], token):
                    self.send_bytes(403, b"Invalid local token"); return
                if data.get("action") == ["case"]:
                    case = data.get("case", [""])[0]
                    if case not in CASES:
                        raise ValueError("Unknown case")
                    with lock:
                        if pending_download() and case != "update":
                            self.send_bytes(409, "有效包已下载，请先完成本轮安装。".encode()); return
                        write_json(root / "state.json", {"case": case})
                    event("selected-case", case=case)
                elif data.get("action") == ["draft"]:
                    mode = data.get("mode", [""])[0]
                    if mode not in ("readonly", "writable"):
                        raise ValueError("Unknown draft mode")
                    fixture = root / "media" / "只读草稿测试.png"
                    expected = json.loads((root / "media-manifest.json").read_text())[fixture.name]
                    if fixture.parent.is_symlink():
                        raise ValueError("Test fixture directory changed")
                    fd = os.open(fixture, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    try:
                        details = os.fstat(fd)
                        if (not stat.S_ISREG(details.st_mode) or details.st_nlink != 1
                                or [details.st_dev, details.st_ino] != expected["identity"]
                                or details.st_size > 1024 * 1024
                                or hashlib.sha256(os.read(fd, details.st_size + 1)).hexdigest() != expected["sha256"]):
                            raise ValueError("Test fixture changed; preserve it and stop")
                        os.fchmod(fd, 0o444 if mode == "readonly" else 0o644)
                    finally:
                        os.close(fd)
                    event("draft-permission", mode=mode)
                elif data.get("action") in (["baseline"], ["verify"]):
                    action = data["action"][0]
                    command = [sys.executable, "-B", str(Path(__file__).with_name("verify_acceptance.py"))]
                    if action == "baseline":
                        command.append("--baseline")
                    checked = subprocess.run(command, capture_output=True, text=True, timeout=15)
                    result = json.loads(checked.stdout)
                    summary = {"time": now(), "action": action, "status": result["status"],
                               "version": result.get("application", {}).get("version"),
                               "build": result.get("application", {}).get("build"),
                               "pids": result.get("application", {}).get("pids"),
                               "mediaComparison": result.get("mediaComparison"),
                               "evidence": result.get("evidencePath"), "reason": result.get("reason")}
                    write_json(evidence / "console-verification-summary.json", summary)
                    event("independent-verification", action=action, status=result["status"])
                    if action == "baseline" and result["status"] == "baseline_created":
                        start_watch()
                elif data.get("action") == ["watch"]:
                    start_watch()
                else:
                    raise ValueError("Unknown action")
                self.send_response(303); self.send_header("Location", "/"); self.send_header("Content-Length", "0"); self.end_headers()
            except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                self.send_bytes(400, str(error).encode("utf-8"))

        def do_GET(self):
            if not self.local_host():
                self.send_bytes(403, b"Local host required"); return
            parsed = urlsplit(self.path)
            path, case = parsed.path, current_case()
            try:
                if path == "/":
                    self.send_bytes(200, page(), "text/html; charset=utf-8"); return
                if path == "/appcast.xml":
                    event("appcast", case=case, installedBuild=installed_build())
                    if case == "timeout":
                        time.sleep(90)
                    if case == "404": self.send_bytes(404, b"FN12 intentional 404\n")
                    elif case == "invalid": self.send_bytes(200, b"<rss><channel><item>broken XML", "application/xml")
                    else:
                        # Bind the ZIP request to the appcast that advertised it,
                        # even if the operator changes the next-check scenario.
                        body = re.sub(rb'(<enclosure url="[^"]+)(")',
                                      lambda match: match[1] + f"?scenario={case}".encode() + match[2],
                                      appcast(manifest, case), count=1)
                        self.send_bytes(200, body, "application/rss+xml; charset=utf-8")
                    return
                if path.startswith(("/archives/", "/slow/")):
                    scenario = parse_qs(parsed.query).get("scenario", [])
                    if len(scenario) != 1 or scenario[0] not in CASES:
                        self.send_bytes(400, b"Appcast scenario required"); return
                    case = scenario[0]
                    filename = path.rsplit("/", 1)[-1]
                    allowed = {item["filename"] for item in manifest["archives"].values()} | {manifest["corruptFilename"]}
                    if filename not in allowed:
                        self.send_bytes(404, b"Unknown fixture"); return
                    archive = root / "feed-assets" / filename
                    event("archive-start", case=case, filename=filename)
                    self.send_response(200); self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(archive.stat().st_size))
                    self.send_header("Cache-Control", "no-store"); self.end_headers()
                    with archive.open("rb") as stream:
                        while chunk := stream.read(4096 if path.startswith("/slow/") else 65536):
                            self.wfile.write(chunk); self.wfile.flush()
                            if path.startswith("/slow/"): time.sleep(.5)
                    event("archive-complete", case=case, filename=filename)
                    if case in ("update", "slow-download") and filename == manifest["archives"]["13"]["filename"]:
                        with lock:
                            write_json(root / "valid-download-served.json", {"time": now(), "filename": filename, "note": "Transfer only; not proof of native verification or installation."})
                            write_json(root / "state.json", {"case": "update"})
                    return
                self.send_bytes(404, b"Unknown fixture route")
            except (BrokenPipeError, ConnectionResetError):
                event("client-cancelled", case=case, path=path)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print(f"FN12 acceptance console: http://127.0.0.1:{port}/", flush=True)
    print(f"Sparkle feed: {manifest['feedURL']}", flush=True)
    print("No app launch, installation, production change or note content API.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
