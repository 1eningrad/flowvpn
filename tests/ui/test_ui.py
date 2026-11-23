"""Browser tests of the web UI against a fake router (tests/ui/mock.py).

    pip install playwright && playwright install chromium
    python3 tests/ui/test_ui.py                   # bundled Chromium
    UI_BROWSER=chrome python3 tests/ui/test_ui.py # installed Google Chrome
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mock import serve  # noqa: E402
from playwright.sync_api import expect, sync_playwright  # noqa: E402

PHONE = {"width": 375, "height": 812}
DESKTOP = {"width": 1280, "height": 900}
TABS = ["home", "routing", "devices", "logs", "diagnose", "settings"]


class UI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(channel=os.environ.get("UI_BROWSER") or None)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()

    def setUp(self):
        self.router, self.srv, self.url = serve()

    def tearDown(self):
        self.ctx.close()
        self.srv.shutdown()
        self.srv.server_close()
        self.assertEqual(self.errors, [])

    def open(self, viewport=DESKTOP):
        self.ctx = self.browser.new_context(viewport=viewport)
        self.page = p = self.ctx.new_page()
        self.errors = []
        self.dialogs, self.accept = [], True
        p.on("pageerror", lambda e: self.errors.append(str(e)))

        def dialog(d):
            self.dialogs.append(d.message)
            d.accept() if self.accept else d.dismiss()
        p.on("dialog", dialog)
        p.goto(self.url)
        expect(p.locator("#statusTitle")).to_have_text("Подключено")
        return p

    def tab(self, name):
        self.page.evaluate("n=>showTabMobile(n)", name)

    def toggle(self, id_):
        self.page.locator(f"label.toggle:has(#{id_})").click()

    def calls(self, action):
        return [c for c in self.router.calls if c["action"] == action]

    def toast(self, text):
        expect(self.page.locator(".toast", has_text=text).first).to_be_visible()

    # --- layout
    def test_no_horizontal_overflow(self):
        p = self.open(PHONE)
        for t in TABS:
            self.tab(t)
            p.wait_for_timeout(250)
            with self.subTest(tab=t):
                self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), 375)

    def test_phone_home_tab_owns_the_servers(self):
        p = self.open(PHONE)
        expect(p.locator("#serverList")).to_be_visible()
        p.locator('.bn-item[data-tab="devices"]').click()
        expect(p.locator("#serverList")).to_be_hidden()
        expect(p.locator("#deviceList")).to_be_visible()
        expect(p.locator(".header-mini-toggle")).to_be_visible()
        p.locator('.bn-item[data-tab="home"]').click()
        expect(p.locator("#serverList")).to_be_visible()

    def test_desktop_shows_both_columns(self):
        p = self.open()
        expect(p.locator("#serverList")).to_be_visible()
        expect(p.locator("#sec-routing")).to_be_visible()
        expect(p.locator("#bottomNav")).to_be_hidden()

    # --- status
    def test_failover_badge_visible_only_when_off(self):
        p = self.open()
        expect(p.locator("#failoverBadge")).to_be_visible()
        self.router.cfg["auto_failover"] = True
        p.evaluate("fetchStatus()")
        expect(p.locator("#failoverBadge")).to_be_hidden()

    def test_mode_label_follows_full_tunnel(self):
        self.router.cfg["full_tunnel"] = True
        p = self.open()
        expect(p.locator("#statusMeta")).to_contain_text("включая РФ")

    # --- errors are shown, not swallowed
    def test_stop_error_reason_is_shown(self):
        self.router.fail["stop"] = "another lifecycle op in progress"
        self.open()
        self.toggle("vpnToggle")
        self.toast("Уже выполняется другая операция")

    def test_update_toast_renders_desc(self):
        p = self.open()
        p.evaluate("updateToast('x','Заголовок',{type:'error',desc:'причина'})")
        self.toast("причина")

    def test_device_route_error_is_not_success(self):
        self.router.fail["set-device"] = "another lifecycle op in progress"
        p = self.open()
        self.tab("devices")
        p.locator('.seg-btn[data-dev-id="aa:bb:cc:dd:ee:13"][data-dev-route="direct"]').click()
        self.toast("Маршрут не изменён")

    # --- VPN switch
    def test_cancelled_stop_keeps_both_switches_on(self):
        p = self.open()
        self.accept = False
        self.toggle("vpnToggle")
        p.wait_for_timeout(200)
        self.assertEqual(len(self.dialogs), 1)
        self.assertEqual(self.calls("stop"), [])
        self.assertTrue(p.evaluate("vpnToggle.checked&&vpnMiniToggle.checked"))

    # --- automation
    def test_behaviour_toggles(self):
        p = self.open()
        self.tab("settings")
        for id_, key, value in (("afToggle", "auto_failover", "true"), ("tgToggle", "tput_guard", "false"),
                                ("ruExitToggle", "blocked_exit_countries", "BY")):
            self.toggle(id_)
            p.wait_for_function("id=>!document.getElementById(id).disabled", arg=id_)
            self.assertEqual((self.calls("set-config")[-1]["key"], self.calls("set-config")[-1]["value"]), (key, value))

    def test_last_blocked_country_off(self):
        self.router.cfg["blocked_exit_countries"] = "RU"
        p = self.open()
        self.tab("settings")
        self.toggle("ruExitToggle")
        self.toast("Выключено")
        self.assertEqual(self.calls("set-config")[-1]["value"], "off")

    def test_failed_save_reverts_toggle(self):
        self.router.fail["set-config"] = "boom"
        p = self.open()
        self.tab("settings")
        self.toggle("afToggle")
        self.toast("Не удалось сохранить")
        self.assertFalse(p.evaluate("afToggle.checked"))

    def test_full_tunnel_confirms_and_restarts(self):
        p = self.open()
        self.accept = False
        self.toggle("ftToggle")
        p.wait_for_timeout(150)
        self.assertEqual(self.calls("set-config"), [])
        self.accept = True
        self.toggle("ftToggle")
        self.toast("Весь трафик, включая РФ")
        self.assertEqual(len(self.calls("restart")), 1)

    # --- devices
    def test_device_rules_tri_state(self):
        p = self.open()
        self.tab("devices")
        head = p.locator(".dev-group-header")
        expect(head).to_have_count(3)
        # An IP-keyed rule must be cleared by its own key.
        p.locator('.seg-btn[data-dev-id="aa:bb:cc:dd:ee:11"][data-dev-route="auto"]').click()
        self.toast("как все")
        self.assertNotIn("192.168.10.11", self.router.rules)
        p.locator('.seg-btn[data-dev-id="aa:bb:cc:dd:ee:13"][data-dev-route="vpn"]').click()
        self.toast("всегда через VPN")
        self.assertEqual(self.router.rules["AA:BB:CC:DD:EE:13"], "vpn")

    # --- domains, log, servers
    def test_domain_search(self):
        p = self.open()
        p.locator("#directCard > .card-head").click()
        expect(p.locator("#directDomains .tag-readonly").first).to_be_hidden()
        p.fill("#directSearch", "b15")
        expect(p.locator("#directDomains .tag")).to_have_count(11)
        p.fill("#directSearch", "zzz")
        expect(p.locator("#directDomains")).to_contain_text("В списке нет")

    def test_log_defaults_to_no_dns(self):
        p = self.open()
        self.tab("logs")
        expect(p.locator("#logList")).to_contain_text("ya.ru")
        self.assertEqual(self.calls("get-log")[0]["filter"], "conn")

    def test_ping_survives_reload(self):
        p = self.open()
        p.click("#pingBtn")
        expect(p.locator("#serverList")).to_contain_text("40 мс")
        p.reload()
        expect(p.locator("#serverList")).to_contain_text("40 мс")
        expect(p.locator(".ping-old")).to_have_count(4)

    def test_protocol_tag_only_for_mixed_lists(self):
        p = self.open()
        expect(p.locator(".server-proto")).to_have_count(0)
        self.router.protocols[0] = "hysteria2"
        p.evaluate("fetchStatus()")
        expect(p.locator(".server-proto")).to_have_count(4)

    def test_release_notes_render_markdown_safely(self):
        body = (Path(__file__).parents[2] / "docs/releases/v2026.11.1.md").read_text(encoding="utf-8")
        self.router.notes = body + "\n- <img src=x onerror=window.pwned=1> **<script>window.pwned=1</script>**"
        p = self.open(PHONE)
        self.tab("settings")
        p.click("#updCheckBtn")
        n = p.locator(".upd-notes")
        expect(n).to_contain_text("Windows-установщик в этом релизе не пересобирался")
        text = n.inner_text()
        self.assertNotIn("**", text)
        self.assertNotIn("##", text)
        self.assertEqual(n.locator("img,script").count(), 0)
        self.assertIsNone(p.evaluate("window.pwned||null"))
        self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), 375)

    def test_plurals(self):
        p = self.open()
        for t in ("1 домен", "3 домена", "11 доменов"):
            expect(p.locator("#presetsList")).to_contain_text(t)


if __name__ == "__main__":
    unittest.main()
