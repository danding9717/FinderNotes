#!/usr/bin/env python3
"""Localhost fixtures for the real Sparkle updater, not an updater implementation.

Run after prepare_review.py; change state with --set-case CASE in another process.
All requests use the real Sparkle download/signature/install path in the review app.
"""

import argparse
import base64
import html
import json
import mimetypes
import plistlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from prepare_review import VARIANTS


CASES = ("update", "latest", "local-ahead", "404", "invalid", "timeout",
         "bad-signature", "corrupt", "slow-download")


def appcast(manifest, case):
    installed = Path(manifest["installedApp"]) / "Contents" / "Info.plist"
    with installed.open("rb") as stream:
        current_build = str(plistlib.load(stream)["CFBundleVersion"])
    archive = manifest["archives"][current_build if case in ("latest", "local-ahead") else "13"]
    version = str(int(current_build) - 1) if case == "local-ahead" else archive["version"]
    short_version = "0.1.0" if case == "local-ahead" else archive["shortVersion"]
    filename, length, signature = archive["filename"], archive["length"], archive["signature"]
    if case == "corrupt":
        filename, length = manifest.get("corruptFilename", "FinderNotes-FN12Review-corrupt.zip"), manifest["corruptLength"]
    if case == "bad-signature":
        signature = base64.b64encode(bytes(64)).decode("ascii")
    prefix = "/slow/" if case == "slow-download" else "/archives/"
    url = f"http://localhost:{manifest['port']}{prefix}{filename}"
    title = html.escape(manifest.get("displayName", "FinderNotes FN12 Review"))
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>{title}</title><item>
<title>{title} {html.escape(short_version)}（{version}）</title>
<description><![CDATA[<h2>FN12 隔离更新测试</h2><p>独立测试身份；验证原生检查、安装、草稿保护和同路径替换。</p>]]></description>
<sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<enclosure url="{html.escape(url, quote=True)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>'''.encode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=VARIANTS, default="standard")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--set-case", choices=CASES)
    args = parser.parse_args()
    project_build = Path(__file__).resolve().parents[2] / ".build"
    allowed = {project_build / variant["directory"] for variant in VARIANTS.values()}
    default_root = project_build / VARIANTS[args.variant]["directory"]
    root = args.root.resolve() if args.root else default_root.resolve()
    if root not in {path.resolve() for path in allowed}:
        raise SystemExit("Fixture root must be one of this worktree's fixed FN12 validation directories.")
    manifest = json.loads((root / "manifest.json").read_text())
    if args.set_case:
        replacement = root / "state.tmp"
        replacement.write_text(json.dumps({"case": args.set_case}) + "\n")
        replacement.replace(root / "state.json")
        print(f"Next request: {args.set_case}")
        return
    log_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *values):
            with log_lock:
                with (root / "requests.log").open("a") as log:
                    log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {self.address_string()} {format % values}\n")

        def send_bytes(self, status, body, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            case = json.loads((root / "state.json").read_text())["case"]
            try:
                if path == "/appcast.xml":
                    if case == "timeout":
                        time.sleep(90)
                    if case == "404":
                        self.send_bytes(404, b"FN12 intentional 404\n", "text/plain")
                    elif case == "invalid":
                        self.send_bytes(200, b"<rss><channel><item>broken XML", "application/xml")
                    else:
                        self.send_bytes(200, appcast(manifest, case), "application/rss+xml; charset=utf-8")
                    return
                if path.startswith(("/archives/", "/slow/")):
                    filename = path.rsplit("/", 1)[-1]
                    archive = root / "feed-assets" / filename
                    if filename not in {item["filename"] for item in manifest["archives"].values()} | {manifest.get("corruptFilename", "FinderNotes-FN12Review-corrupt.zip")}:
                        self.send_bytes(404, b"unknown fixture\n", "text/plain")
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", mimetypes.guess_type(filename)[0] or "application/octet-stream")
                    self.send_header("Content-Length", str(archive.stat().st_size))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    with archive.open("rb") as stream:
                        while chunk := stream.read(4096 if path.startswith("/slow/") else 65536):
                            self.wfile.write(chunk)
                            self.wfile.flush()
                            if path.startswith("/slow/"):
                                time.sleep(.5)
                    return
                self.send_bytes(404, b"unknown fixture\n", "text/plain")
            except (BrokenPipeError, ConnectionResetError):
                self.log_message("client cancelled %s", path)

    server = ThreadingHTTPServer(("127.0.0.1", manifest["port"]), Handler)
    server.daemon_threads = True
    print(f"FN12 localhost fixture: {manifest['feedURL']}", flush=True)
    print("Cases: " + ", ".join(CASES), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
