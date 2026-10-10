#!/usr/bin/env python3
"""Stateless independent localhost fixtures for NativeNetworkChecks.m."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from fixture_server import appcast, CASES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18773)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2] / ".build" / "FN12Validation"
    manifest = json.loads((root / "manifest.json").read_text())
    manifest["port"] = args.port
    manifest["installedApp"] = str(root / "versions" / "12" / "FinderNotes FN12 Review.app")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *values):
            with (root / "network" / "requests.log").open("a") as log:
                log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {fmt % values}\n")

        def do_GET(self):
            path = urlsplit(self.path).path
            try:
                if path.startswith("/case/"):
                    case = path.rsplit("/", 1)[-1]
                    if case not in CASES:
                        self.send_error(404)
                        return
                    if case == "timeout":
                        time.sleep(90)
                    if case == "404":
                        self.send_error(404)
                        return
                    body = b"<rss><channel><item>broken XML" if case == "invalid" else appcast(manifest, case)
                    self.send_response(200)
                    self.send_header("Content-Type", "application/rss+xml")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if path.startswith(("/archives/", "/slow/")):
                    filename = path.rsplit("/", 1)[-1]
                    allowed = {item["filename"] for item in manifest["archives"].values()} | {"FinderNotes-FN12Review-corrupt.zip"}
                    if filename not in allowed:
                        self.send_error(404)
                        return
                    archive = root / "feed-assets" / filename
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(archive.stat().st_size))
                    self.end_headers()
                    with archive.open("rb") as stream:
                        while chunk := stream.read(4096 if path.startswith("/slow/") else 65536):
                            self.wfile.write(chunk)
                            self.wfile.flush()
                            if path.startswith("/slow/"):
                                time.sleep(.5)
                    return
                self.send_error(404)
            except (BrokenPipeError, ConnectionResetError):
                self.log_message("client cancelled %s", path)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"Native network fixture on localhost:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
