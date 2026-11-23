"""Stateful fake router: serves the built UI and answers /cgi-bin/eclipvpn."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PAGE = Path(__file__).resolve().parents[2] / "www/eclipvpn/index.html"
NAMES = ["🇦🇹 Австрия", "🇩🇪 Германия", "🇺🇿 Узбекистан · тест", "🇷🇺 Россия"]


class Router:
    def __init__(self):
        self.calls = []      # every mutating request, as dicts
        self.fail = {}       # action -> error text
        self.incidents = []
        self.notes = ""
        self.rules = {"192.168.10.11": "vpn", "AA:BB:CC:DD:EE:12": "direct"}
        self.protocols = ["vless"] * 4
        self.cfg = dict(auto_failover=False, tput_guard=True, net_check_switch=True,
                        blocked_exit_countries="RU,BY", full_tunnel=False, mode="all_vpn")

    def answer(self, g):
        a = g.get("action", "")
        if a in ("set-config", "set-device", "remove-device-route", "restart",
                 "start", "stop", "get-log", "set-mode"):
            self.calls.append(g)
        if a in self.fail:
            return {"error": self.fail[a]}
        if a == "status":
            return dict(self.cfg, running=True, server=NAMES[2], uptime=4000, selected=2,
                        servers=[dict(name=n, host=f"h{i}", port=443, protocol=self.protocols[i],
                                      sub_id="a", sub_name="X", muted=i == 1) for i, n in enumerate(NAMES)],
                        subscriptions=[dict(id="a", name="EclipVPN", url="https://example.com/a/very/long/path", enabled=True)],
                        subscription_url="x", vpn_ip="203.0.113.139", auto_start=True, auto_mode=False,
                        device_rules=self.rules, subscription_meta={})
        if a == "net-check":
            return dict(internet="full")
        if a == "get-incidents":
            return dict(incidents=self.incidents, stats=[])
        if a == "update-check":
            return dict(current="1", latest="v2", available=True, url="https://github.com/a/b", notes=self.notes)
        if a == "ping":
            return [dict(index=i, ping=40 + i * 150) for i in range(4)]
        if a == "get-devices":
            return [dict(name="yeelink-light-with-a-very-long-name", ip=f"192.168.10.{i}",
                         mac=f"aa:bb:cc:dd:ee:{i}") for i in range(10, 20)]
        if a == "get-domains":
            return dict(ru_domains_builtin=[f"b{i}.ru" for i in range(200)], vpn_domains_builtin=["openai.com"],
                        custom_direct=["lamoda.ru"], custom_vpn=[])
        if a == "preset":
            return dict(presets=[dict(name="youtube", enabled=False, domain_count=n) for n in (1, 3, 11)])
        if a == "get-log":
            return [dict(time="x 10:00:01", dst="ya.ru:443", route="direct")]
        if a == "set-device":
            self.rules[g["ip"].upper()] = g["route"]
        if a == "remove-device-route":
            self.rules.pop(g["ip"].upper(), None)
        if a == "set-config":
            v = g["value"]
            self.cfg[g["key"]] = {"true": True, "false": False, "off": ""}.get(v, v)
        return {}


def serve():
    router = Router()

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            u = urlparse(self.path)
            if u.path.startswith("/eclipvpn"):
                body, ctype = PAGE.read_bytes(), "text/html; charset=utf-8"
            else:
                g = {k: v[0] for k, v in parse_qs(u.query).items()}
                body, ctype = json.dumps(router.answer(g)).encode(), "application/json"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            try:
                self.wfile.write(body)
            except OSError:
                pass  # page closed mid-poll

        do_POST = do_GET

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return router, srv, f"http://127.0.0.1:{srv.server_port}/eclipvpn/"
