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
TABS = ["servers", "routing", "devices", "logs", "diagnose", "settings"]


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
        p = self.open_raw(viewport)
        expect(p.locator("#powBtn")).to_have_text("Отключить")
        return p

    def open_raw(self, viewport=DESKTOP):
        self.ctx = self.browser.new_context(viewport=viewport)
        self.page = p = self.ctx.new_page()
        self.errors = []
        p.on("pageerror", lambda e: self.errors.append(str(e)))

        p.goto(self.url)
        return p

    def tab(self, name):
        self.page.evaluate("n=>showTabMobile(n)", name)

    def toggle(self, id_):
        self.page.locator(f"label.toggle:has(#{id_})").click()

    def answer(self, yes):
        expect(self.page.locator("#dlg")).to_be_visible()
        self.page.click("#dlgOk" if yes else "#dlgCancel")
        expect(self.page.locator("#dlg")).to_be_hidden()

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

    def test_phone_sections_shrink_the_stage(self):
        p = self.open(PHONE)
        expect(p.locator("#serverList")).to_be_visible()
        p.locator('.tab[data-tab="devices"]').click()
        expect(p.locator("#serverList")).to_be_hidden()
        expect(p.locator("#deviceList")).to_be_visible()
        expect(p.locator("#powBtn")).to_be_hidden()
        p.locator('.tab[data-tab="servers"]').click()
        expect(p.locator("#powBtn")).to_be_visible()

    def test_desktop_stage_stays_beside_every_section(self):
        p = self.open()
        for t in TABS:
            self.tab(t)
            expect(p.locator("#powBtn")).to_be_in_viewport()

    def test_low_window_keeps_power_button(self):
        p = self.open({"width": 1280, "height": 600})
        expect(p.locator("#powBtn")).to_be_in_viewport()

    def test_touch_targets(self):
        p = self.open(PHONE)
        for t in TABS:
            self.tab(t)
            p.wait_for_timeout(250)
            small = p.evaluate("""()=>[...document.querySelectorAll('#stage button,.tab,.section.active button,.section.active input:not([type=checkbox]):not([type=file]),.section.active .server')]
              .filter(e=>e.offsetParent).map(e=>[(e.id||e.className||e.textContent),e.getBoundingClientRect().height]).filter(x=>x[1]<43.5)""")
            with self.subTest(tab=t):
                self.assertEqual(small, [])

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
        self.page.click("#powBtn")
        self.answer(True)
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
    def test_cancelled_stop_changes_nothing(self):
        p = self.open()
        p.click("#powBtn")
        p.evaluate("fetchStatus()")
        self.answer(False)
        self.assertEqual(self.calls("stop"), [])
        expect(p.locator("#powBtn")).to_have_text("Отключить")

    def test_stop_and_start(self):
        p = self.open()
        p.click("#powBtn")
        self.answer(True)
        expect(p.locator("#statusTitle")).to_have_text("Выключен")
        expect(p.locator("#stage")).to_have_class("off")
        p.click("#powBtn")
        expect(p.locator("#statusTitle")).to_have_text("Узбекистан")

    def test_dead_server_offers_the_fastest_one(self):
        self.router.link = "lost"
        p = self.open_raw()
        expect(p.locator("#stage")).to_have_class("lost")
        expect(p.locator("#statusMeta")).to_contain_text("Сам сервер не сменится")
        expect(p.locator("#altBtn")).to_be_visible()
        self.assertEqual(self.calls("auto-select"), [])  # never on its own
        p.click("#powBtn")
        expect(p.locator("#statusTitle")).to_have_text("Австрия")
        expect(p.locator("#powBtn")).to_have_text("Отключить")

    def test_provider_outage_does_not_offer_switching(self):
        self.router.link = "wan"
        p = self.open_raw()
        expect(p.locator("#statusPre")).to_contain_text("Нет интернета у провайдера")
        expect(p.locator("#powBtn")).to_have_text("Отключить")
        expect(p.locator("#altBtn")).to_be_hidden()

    def test_old_backend_without_link_reads_as_ok(self):
        self.router.link = None
        p = self.open()
        expect(p.locator("#statusPre")).to_contain_text("Подключено через")

    def test_switch_server(self):
        p = self.open()
        p.locator(".server").nth(0).click()
        expect(p.locator("#statusTitle")).to_have_text("Австрия")
        expect(p.locator("#powBtn")).to_have_text("Отключить")
        self.assertEqual(len(self.calls("set-server")), 1)

    def test_cancel_while_probing(self):
        self.router.probe_delay = 1.5
        p = self.open()
        p.locator(".server").nth(0).click()
        expect(p.locator("#powBtn")).to_have_text("Отменить")
        expect(p.locator("#stage")).to_have_class("busy")
        p.click("#powBtn")
        expect(p.locator("#statusTitle")).to_have_text("Узбекистан")
        p.wait_for_timeout(2000)
        self.assertEqual(self.calls("set-server"), [])
        expect(p.locator(".server.active")).to_contain_text("Узбекистан")

    def test_failed_probe_rolls_back(self):
        self.router.fail["probe-server"] = "server unreachable"
        p = self.open()
        p.locator(".server").nth(0).click()
        self.toast("Сервер не отвечает")
        expect(p.locator("#statusTitle")).to_have_text("Узбекистан")
        self.assertEqual(self.calls("set-server"), [])

    def test_long_names_fit(self):
        p = self.open(PHONE)
        for n, title in (("Россия (прямой)", "Россия"), ("Объединённые Арабские Эмираты", "Объединённые Арабские Эмираты"),
                         ("🇳🇱 auto-nl-03.example.net | LTE", "auto-nl-03.example.net")):
            p.evaluate("n=>{state.server=n;renderStage()}", n)
            expect(p.locator("#statusTitle")).to_have_text(title)
            self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), 375)

    def test_names_are_not_html(self):
        p = self.open()
        p.evaluate("state.server='X · <img src=x onerror=window.pwned=1>';renderStage()")
        self.assertEqual(p.locator("#stage img").count(), 0)
        self.assertIsNone(p.evaluate("window.pwned||null"))

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
        self.tab("routing")
        self.toggle("ftToggle")
        self.answer(False)
        p.wait_for_function("!ftToggle.disabled&&!ftToggle.checked")
        self.assertEqual(self.calls("set-config"), [])
        self.toggle("ftToggle")
        self.answer(True)
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
        self.tab("routing")
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

    def test_update_is_an_event_not_a_failure(self):
        self.router.incidents = [dict(ts=1795457111, type="update", host="", server="", detail="обновлено до v2")]
        p = self.open()
        self.tab("logs")
        expect(p.locator("#logStats")).to_contain_text("Напрямую")
        expect(p.locator("#incidentsBadge")).to_be_hidden()
        p.locator('.log-filter[data-filter="incidents"]').click()
        expect(p.locator(".incident.ok")).to_contain_text("обновлено до v2")
        expect(p.locator(".incident-server")).to_have_count(0)
        expect(p.locator("#logStats")).to_have_text("")
        expect(p.locator("#logCount")).to_have_text("1")
        self.router.incidents.append(dict(ts=1795457000, type="update_rollback", host="", server="", detail="x"))
        expect(p.locator("#incidentsBadge")).to_have_text("1")
        expect(p.locator(".incident:not(.ok)")).to_have_count(1)

    def test_escape_dismisses_dialog(self):
        p = self.open()
        p.click("#powBtn")
        expect(p.locator("#dlg")).to_be_visible()
        p.keyboard.press("2")  # tab shortcut is off under a dialog
        p.keyboard.press("Escape")
        expect(p.locator("#dlg")).to_be_hidden()
        expect(p.locator("#sec-servers")).to_be_visible()
        self.assertEqual(self.calls("stop"), [])

    def test_rename_prompt(self):
        p = self.open()
        self.tab("settings")
        p.click('[aria-label="Переименовать"]')
        p.fill("#dlgInput", "Новое")
        p.keyboard.press("Enter")
        expect(p.locator("#dlg")).to_be_hidden()
        self.toast("Переименовано")

    def test_badge_opens_automation(self):
        p = self.open()
        p.click("#failoverBadge")
        expect(p.locator("#automationCard")).to_be_in_viewport()

    def test_servers_on_first_phone_screen(self):
        p = self.open(PHONE)
        self.assertLess(p.locator(".server").first.bounding_box()["y"], 340)

    def test_schedule_times_only_when_enabled(self):
        p = self.open()
        self.tab("settings")
        expect(p.locator("#schedOn")).to_be_hidden()
        self.toggle("schedToggle")
        expect(p.locator("#schedOn")).to_be_visible()

    def test_plurals(self):
        p = self.open()
        for t in ("1 домен", "3 домена", "11 доменов"):
            expect(p.locator("#presetsList")).to_contain_text(t)


if __name__ == "__main__":
    unittest.main()
