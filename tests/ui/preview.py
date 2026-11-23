"""Preview the built UI on a live router's data WITHOUT deploying it.

    python3 tests/ui/preview.py 192.168.10.1     # then open http://127.0.0.1:8796/eclipvpn/

Read-only: only the GET actions below reach the router; anything that would
change it is answered locally with an error.
"""
import json
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PAGE = Path(__file__).resolve().parents[2] / "www/eclipvpn/index.html"
READ = {"status", "net-check", "get-devices", "get-domains", "get-log", "get-incidents", "get-traffic",
        "traffic-poll", "system-info", "update-check", "update-status", "ping", "healthcheck"}


def allowed(g):
    a = g.get("action", "")
    if a in READ:
        return True
    extra = set(g) - {"action", "_"}
    return (a in ("schedule", "auto-update") and not extra) or (a in ("preset", "sub") and g.get("op") == "list" and extra == {"op"})


class H(BaseHTTPRequestHandler):
    def send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/eclipvpn"):
            return self.send(PAGE.read_bytes(), "text/html; charset=utf-8")
        g = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
        if not allowed(g):
            return self.deny()
        try:
            with urllib.request.urlopen(f"http://{ROUTER}/cgi-bin/eclipvpn?{u.query}", timeout=90) as r:
                self.send(r.read(), "application/json")
        except OSError as e:
            self.send(json.dumps({"error": str(e)}).encode(), "application/json")

    def deny(self):
        self.send(json.dumps({"error": "Просмотр: изменения на роутер не отправляются"}, ensure_ascii=False).encode(), "application/json")

    do_POST = deny

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ROUTER = sys.argv[1]
    ThreadingHTTPServer(("127.0.0.1", 8796), H).serve_forever()
