from __future__ import annotations

import html
import http.cookies
import json
import mimetypes
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PUBLIC_ROOT = Path(os.environ.get("CASES_PREVIEW_PUBLIC", Path(__file__).with_name("public"))).resolve()
BACKEND_URL = os.environ.get("CASES_BACKEND_URL", "http://127.0.0.1:18082").rstrip("/")
PASSWORD = os.environ.get("CASES_PREVIEW_PASSWORD", "")
HOST = "127.0.0.1"
PORT = int(os.environ.get("CASES_PREVIEW_PORT", "8767"))
SESSION_COOKIE = "__Host-cases_preview"
SESSION_TTL = 12 * 60 * 60
MAX_BODY = 1024 * 1024
sessions: dict[str, float] = {}
failed_logins: dict[str, list[float]] = {}

LOGIN_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CASES — Private preview</title>
<style>
:root{color-scheme:dark;font-family:system-ui,sans-serif;background:#10171a;color:#eee8dc}
body{min-height:100vh;display:grid;place-items:center;margin:0}
main{width:min(90vw,420px);padding:2rem;border:1px solid #756448;border-radius:12px;background:#182124}
h1{font-size:1.45rem;margin:0 0 .5rem}p{color:#c6c2b9;line-height:1.5}
label{display:block;margin:1.5rem 0 .5rem}input{box-sizing:border-box;width:100%;padding:.85rem;border:1px solid #756448;border-radius:6px;background:#0d1315;color:#fff;font-size:1rem}
button{margin-top:1rem;padding:.8rem 1rem;border:0;border-radius:6px;background:#c5a66d;color:#171717;font-weight:700;font-size:1rem;cursor:pointer}
.error{color:#ff9c8f;min-height:1.5em}
</style></head><body><main><h1>CASES — private preview</h1>
<p>Enter the review password to open the Paris 1919 negotiation game.</p>
<form method="post" action="/__login"><label for="password">Access password</label>
<input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
<button type="submit">Open game</button><p class="error">__ERROR__</p></form></main></body></html>"""

MIME = {
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
}


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


class PreviewHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CASESPreview"

    def version_string(self) -> str:
        return "CASES-Preview"

    def log_message(self, fmt: str, *args: object) -> None:
        # Never log request bodies, cookies, authorization headers, or query values.
        print(f"{self.log_date_time_string()} {self.command} {urllib.parse.urlsplit(self.path).path} {args[1] if len(args) > 1 else ''}", flush=True)

    def _send(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8",
              headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", headers.get("Cache-Control", "no-store") if headers else "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        if headers:
            for key, value in headers.items():
                if key.lower() != "cache-control":
                    self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _cookie_session(self) -> str:
        jar = http.cookies.SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
            token = jar[SESSION_COOKIE].value if SESSION_COOKIE in jar else ""
        except Exception:
            return ""
        expiry = sessions.get(token, 0.0)
        if expiry <= time.time():
            sessions.pop(token, None)
            return ""
        return token

    def _is_api(self, path: str) -> bool:
        return path in ("/healthz", "/readyz") or path.startswith("/api/v1/")

    def _login_page(self, message: str = "") -> None:
        body = LOGIN_HTML.replace("__ERROR__", html.escape(message)).encode("utf-8")
        self._send(200, body, "text/html; charset=utf-8")

    def _redirect_to_login(self) -> None:
        self._send(303, b"", headers={"Location": "/login"})

    def _serve_static(self, request_path: str) -> None:
        decoded = urllib.parse.unquote(request_path)
        relative = "index.html" if decoded in ("", "/") else decoded.lstrip("/")
        candidate = (PUBLIC_ROOT / relative).resolve()
        if candidate != PUBLIC_ROOT and PUBLIC_ROOT not in candidate.parents:
            self._send(403, b"Forbidden")
            return
        if not candidate.is_file():
            self._send(404, b"Not found")
            return
        try:
            body = candidate.read_bytes()
        except OSError:
            self._send(404, b"Not found")
            return
        content_type = MIME.get(candidate.suffix.lower(), mimetypes.guess_type(candidate.name)[0] or "application/octet-stream")
        cache = "no-cache" if candidate.name == "index.html" else "private, max-age=3600"
        self._send(200, body, content_type, {"Cache-Control": cache})

    def _proxy_api(self, method: str) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        if not self._is_api(parsed.path):
            self._send(404, b"Not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b"Invalid content length")
            return
        if length < 0 or length > MAX_BODY:
            self._send(413, b"Request too large")
            return
        body = self.rfile.read(length) if length else None
        headers: dict[str, str] = {}
        for name in ("Accept", "Content-Type", "Authorization", "Idempotency-Key"):
            value = self.headers.get(name)
            if value:
                headers[name] = value
        upstream = BACKEND_URL + parsed.path
        if parsed.query:
            upstream += "?" + parsed.query
        request = urllib.request.Request(upstream, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=360) as response:
                payload = response.read()
                status = response.status
                content_type = response.headers.get("Content-Type", "application/json")
                retry_after = response.headers.get("Retry-After")
        except urllib.error.HTTPError as error:
            payload = error.read()
            status = error.code
            content_type = error.headers.get("Content-Type", "application/json")
            retry_after = error.headers.get("Retry-After")
        except Exception:
            self._send(502, json_bytes({"detail": "The local CASES backend is unavailable."}), "application/json")
            return
        response_headers = {}
        if retry_after:
            response_headers["Retry-After"] = retry_after
        self._send(status, payload, content_type, response_headers)

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == "/login":
            if self._cookie_session():
                self._send(303, b"", headers={"Location": "/"})
            else:
                self._login_page()
            return
        if not self._cookie_session():
            if self._is_api(path):
                self._send(401, json_bytes({"detail": "Preview login required."}), "application/json")
            else:
                self._redirect_to_login()
            return
        if self._is_api(path):
            self._proxy_api("GET")
            return
        self._serve_static(path)

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == "/__login":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > 4096:
                    self._send(400, b"Invalid login request")
                    return
                form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
                submitted = form.get("password", [""])[0]
            except Exception:
                self._send(400, b"Invalid login request")
                return
            peer = self.client_address[0]
            now = time.time()
            recent = [stamp for stamp in failed_logins.get(peer, []) if now - stamp < 600]
            failed_logins[peer] = recent
            if len(recent) >= 8:
                self._send(429, b"Too many attempts")
                return
            if not PASSWORD or not secrets.compare_digest(submitted, PASSWORD):
                failed_logins[peer].append(now)
                self._login_page("Password not accepted.")
                return
            failed_logins.pop(peer, None)
            token = secrets.token_urlsafe(32)
            sessions[token] = now + SESSION_TTL
            self._send(303, b"", headers={
                "Location": "/",
                "Set-Cookie": f"{SESSION_COOKIE}={token}; Path=/; Max-Age={SESSION_TTL}; Secure; HttpOnly; SameSite=Strict",
            })
            return
        if path == "/__logout":
            token = self._cookie_session()
            sessions.pop(token, None)
            self._send(303, b"", headers={
                "Location": "/login",
                "Set-Cookie": f"{SESSION_COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict",
            })
            return
        if not self._cookie_session():
            self._send(401, json_bytes({"detail": "Preview login required."}), "application/json")
            return
        if self._is_api(path):
            self._proxy_api("POST")
            return
        self._send(405, b"Method not allowed")

    def do_HEAD(self) -> None:
        self.do_GET()


def main() -> None:
    if not PASSWORD:
        raise SystemExit("CASES_PREVIEW_PASSWORD is required.")
    if not (PUBLIC_ROOT / "index.html").is_file():
        raise SystemExit(f"Godot web export not found: {PUBLIC_ROOT / 'index.html'}")
    server = ThreadingHTTPServer((HOST, PORT), PreviewHandler)
    print(f"CASES preview listening on {HOST}:{PORT}; backend={BACKEND_URL}; assets={PUBLIC_ROOT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
