# EclipVPN — план развития

Идеи на будущее, выписанные после анализа конкурентов (ZeroBlock, Passwall, OpenClash, v2raya, homeproxy, xkeen). Не план в строгом смысле — список того, что есть смысл взять, отсортированный по соотношению "польза / сложность".

Принцип отбора: брать только то, что вписывается в позиционирование EclipVPN — минимализм + современный stack (xray + sing-box, только VLESS+Reality). Не превращать в очередной Passwall.

---

## Tier 1 — приоритет: большая польза, маленькая правка

### 1. URLTest — авто-выбор лучшего сервера
**Откуда:** ZeroBlock, Clash, mihomo
**Что:** при старте (и по кнопке "Auto") измеряет latency всех серверов и выбирает лучший автоматически. Сейчас watchdog только переключает при падении.
**Польза:** новичку не надо гадать какой сервер выбрать.
**Где трогать:** `cmd_ping` расширить → `cmd_auto_select` → кнопка "Авто" в UI рядом со списком серверов.
**Оценка:** ~150 строк, 2-3 часа.

### 2. Service presets — пресеты сервисов в один клик
**Откуда:** Passwall, OpenClash
**Что:** на вкладке "Маршрут" чекбоксы: ☐ YouTube ☐ Telegram ☐ ChatGPT ☐ Discord ☐ Spotify ☐ Twitter/X ☐ Instagram. Toggle добавляет/убирает домены в "через VPN".
**Польза:** 90% юзкейсов покрыто 7 кнопками. Не нужно знать какие домены прописывать.
**Где трогать:** статический map в `index.html` (имя→массив доменов) + батч add-domain. Опционально хранить флаг "включён ли preset" в config.
**Оценка:** ~80 строк, 1-2 часа.

### 3. Speed test — реальная скорость, не пинг
**Откуда:** Passwall, v2raya
**Что:** скачать тестовый файл (например `https://speed.cloudflare.com/__down?bytes=10000000`) через каждый сервер, показать MB/s.
**Польза:** ping 30мс ≠ хорошая скорость. Сербия может пинговаться лучше Финляндии но качать в 3 раза медленнее.
**Где трогать:** новая команда `eclipvpn speedtest` (запускает probe xray на уникальном порту, как watchdog), curl с замером времени и размера. Прогресс-бар в UI.
**Оценка:** ~100 строк, 2 часа.

### 4. DNS leak test
**Откуда:** OpenClash diagnostics
**Что:** в диагностике запрос на `https://1.1.1.1/cdn-cgi/trace` и `dnsleaktest.com`, покажет какие резолверы реально видят запросы. Если видит провайдера — есть утечка.
**Польза:** уверенность что VPN реально работает (а не "вроде включён").
**Где трогать:** добавить пункт в `cmd_healthcheck`.
**Оценка:** ~50 строк, 1 час.

### 5. Toast при auto-update подписки
**Откуда:** ZeroBlock
**Что:** уведомление "Подписка обновлена: 7→8 серверов" при cron-обновлении.
**Польза:** видно когда добавились/пропали серверы, не неожиданно.
**Где трогать:** `update_subscription` пишет diff в `/tmp/eclipvpn/last_update.json`, фронт читает и показывает toast если изменилось с прошлой проверки.
**Оценка:** ~30 строк, 30 минут.

### 6. Punycode/IDN для доменов
**Откуда:** ZeroBlock (последний релиз)
**Что:** принимать `сайт.рф` → автоматом конвертить в `xn--80aswg.xn--p1ai` перед сохранением.
**Польза:** не отвергаем кириллические домены.
**Где трогать:** на фронте перед `add-domain` пропустить через punycode (можно встроенно через URL API). На бэке расширить regex чтобы принимал `xn--`.
**Оценка:** ~20 строк, 30 минут.

---

## Tier 2 — полезное, не приоритет

### 7. Auto-restart при смене WAN
**Откуда:** ZeroBlock "Interface Monitoring"
**Что:** при отключении/смене WAN — soft restart VPN автоматически. Решает сценарий "ноутбук переключился с Ethernet на Wi-Fi".
**Где:** hotplug script в `/etc/hotplug.d/iface/99-eclipvpn`.
**Оценка:** ~30 строк.

### 8. Toggle QUIC blocking
**Откуда:** ZeroBlock "Disable QUIC"
**Что:** галочка в настройках "Блокировать QUIC (UDP/443)". Сейчас всегда блокируется. Иногда хочется выключить — облачный гейминг, например.
**Оценка:** ~30 строк.

### 9. Sortable журнал с группировкой по хосту
**Откуда:** OpenClash connections view
**Что:** клик на колонку "Хост" — группировка по домену с агрегацией трафика и количества коннектов.
**Оценка:** ~80 строк JS.

### 10. Subscription update notify в логе
**Откуда:** ZeroBlock "Холостой reload не даёт уведомления в лог"
**Что:** при auto-update подписки логировать только если что-то изменилось. Если 7→7 серверов один к одному — молчать.
**Оценка:** ~20 строк, добавить diff-check к `update_subscription`.

### 11. Per-server SNI override
**Откуда:** ZeroBlock "Нормализация uTLS для странных подписок"
**Что:** в UI на сервере кнопка "⚙ Настроить" — поля для override SNI/fp. Помогает с подписками от китайских провайдеров (QQ).
**Оценка:** ~100 строк.

### 12. Subscription update interval в настройках
**Что:** сейчас auto-update раз в день hardcoded. Сделать "каждый час / раз в день / раз в неделю".
**Оценка:** ~50 строк, расширить cron логику.

### 13. Gaming bypass — пресет + per-port исключения
**Откуда:** реальная боль (lag в Steam-играх через VPN).
**Что:**
- Пресет "Игры напрямую" — добавляет в Direct список домены: `steamcontent.com`, `steamserver.net`, `steamstatic.com`, `steampowered.com`, `csgo.com`, `dota2.com`, `epicgames.com`, `riotgames.com`, `battle.net`, `discord.gg/discord.media` (для голоса).
- Опционально: nft-правило bypass tproxy для UDP портов 27000-27100 (Steam) — экономит ~5-10мс на хоп sing-box даже когда домен не определён.
- Quick-toggle "Gaming mode" на главной — ставит роутер в `blocklist` или конкретный девайс в Direct на 1/2/4 часа, потом вернуть.
**Польза:** не приходится каждый раз в Devices ходить.
**Оценка:** ~150 строк (пресет ~50, nft port bypass ~50, gaming-mode timer ~50).

---

## Tier 3 — большая работа, продумать

### 15. Per-device profiles (multi-section)
**Откуда:** ZeroBlock, реальный пользовательский запрос — "хочу чтобы ПК был по списку для гейминга, а телефон через всё VPN".
**Что:** для каждого устройства можно выбрать профиль маршрутизации, не только on/off:
- `global` (по глобальному режиму, как сейчас)
- `all_vpn` (всё через VPN кроме RU)
- `blocklist` (только заблокированное через VPN)
- `direct` (мимо VPN совсем — уже работает)

**Архитектура:**
```
nft prerouting:
  ether saddr <MAC1> → tproxy :2155 (профиль blocklist)
  ether saddr <MAC2> → tproxy :2156 (профиль all_vpn)
  default            → tproxy :2154 (глобальный)

sing-box config:
  inbounds: [
    {tag: "global",    type: "tproxy", listen_port: 2154},
    {tag: "blocklist", type: "tproxy", listen_port: 2155},
    {tag: "allvpn",    type: "tproxy", listen_port: 2156}
  ]
  route.rules: [
    {inbound: "blocklist", ...правила blocklist...},
    {inbound: "allvpn",    ...правила all_vpn...},
    ...правила global (default)...
  ]
```

**Что переделать:**
- `network.sh` — per-MAC nft с `meta mark` + `tproxy to :PORT` вместо просто `return`
- `singbox.sh` — генерить N inbound'ов и N веток rules с `inbound:` фильтром
- `cmd_set_device_route` — принимать `direct|vpn|all_vpn|blocklist|global`, расширить storage в config (`device_rules: {"MAC": "blocklist"}`)
- CGI валидация route + UI выпадающее меню вместо тоггла VPN/Direct
- В status response добавить per-device profile

**Trade-offs:**
- +20-40 MB RAM (каждый inbound = handler)
- CPU незначительно (на aarch64)
- Random-MAC девайсы (iPhone Private Address) — профиль не "прилипнет" между сменами MAC
- ~+450 строк кода (200 backend + 150 UI + 100 тестов)

**Оценка:** 5-7 часов реальной работы.

**Когда делать:** когда захочется. Текущая глобальная схема покрывает ~95% юзкейсов: переключение `all_vpn` ↔ `blocklist` решает большинство сценариев на всю сеть.

### 16. Trojan support
*(было 13, переехало)* — поддержка `trojan://` в подписке. ~250 строк parser + xray.sh.

### 17. Chain proxy
*(было 14, переехало)* — A→B→exit, когда нужен другой exit IP. Сложно, нишево.

### 16. QR-импорт подписки
**Откуда:** v2raya, мобильные клиенты
**Что:** в onboarding кнопка "Сканировать QR" → камера телефона → URL.
**Стоимость:** ~200 строк (jsQR inline + `getUserMedia`). Сложно тестить.

---

## Что **НЕ** берём принципиально

- **LuCI integration** (Passwall, homeproxy подход) — наш standalone UI лучше, проще, симпатичнее
- **Multi-protocol зоопарк** (SSR, vmess, ss, hysteria1) — старые, не нужны, ломают минимализм
- **Mihomo / Clash как альтернативное ядро** — у нас xray+sing-box stack
- **GUI-редактор конфигов внутри UI** — power-users правят `/etc/eclipvpn/config.json` напрямую через ssh
- **Telegram-бот для уведомлений** — оверкилл для одного роутера

### iplist.opencck.org как источник direct-списков

**Что это:** сервис rekryt/iplist. Отдаёт через API `?format=text&data=cidr4|domains|ip4&site=...` куратированные пулы IP/доменов конкретных российских компаний (Сбер, Альфа, МТС, Авито, госуслуги и т.д.). Поддомен `russia.iplist.opencck.org` — preset для РФ-сервисов: 19 381 доменов и 1 293 CIDR-подсетей с автообновлением.

**Идея была:** заменить наш hardcoded `_fetch_ru_domains` (74 записи) и/или дополнить `geoip-ru` точечными CIDR.

**Почему не делаем:**
1. **Cloudflare cross-pollination — критично.** Их `cidr4` содержит вещи типа `1.0.0.1/32` (это Cloudflare DNS, мы его юзаем для `dns-direct`) и `104.18.30.74/32` (CDN-пул). Маркируя такой IP как direct «потому что какой-то РФ-сайт оттуда обслуживается», мы автоматически отправляем direct'ом и YouTube, и ChatGPT, и любой другой сервис на том же шарде Cloudflare → блокируется.
2. **Мусор:** в списке встречается `100.99.0.0/16` — это CGNAT, не маршрутизируемая сеть, в роутинге смысла нет.
3. **Дублирование:** их 1293 CIDR — почти все уже внутри `geoip-ru` (RIPE NCC RU allocation). 19k доменов — большинство в `geosite-category-ru`. Marginal benefit, real risks.
4. **Слабые места `geosite/geoip-ru`** легко обходятся через Custom Direct в UI — точечно, безопасно, на 30 секунд: `eclipvpn add-domain X direct` для конкретного непокрытого сервиса.

**Когда могло бы быть уместно:** если SagerNet/MetaCubeX заморозят свои rule_set'ы; для соседних стран (BY/KZ); для пресетов «только банки direct» как фичи UI (но мы такого не делаем).

---

## Предлагаемый пакет "v5.0 — usability"

Tier 1 первые 6 пунктов:
- URLTest (auto-select)
- Service presets (one-click YouTube/TG/ChatGPT)
- Speed test
- DNS leak test
- Toast при update подписки
- Punycode для доменов

Итого: ~430 строк, 1 день работы, ощутимый user-visible прогресс без ломки архитектуры.

---

## Что **уже сделано** (из конкурентского ревью v4.6)

Эти штуки взяли у ZeroBlock в v4.6:
- ✅ Отклонение мусорных серверов из подписки (host=0.0.0.0, port≤0)
- ✅ Trim whitespace + base64 без padding в подписке
- ✅ Лог-варнинг "no proxy parsed" с подсказкой
- ✅ "Холостой restart" — no-op если конфиг не менялся
- ✅ Watchdog anti-spam при долгом offline + "all candidates failed"
- ✅ Fail-fast на пустой/не-http subscription_url

---

*Документ живой. Обновлять по мере того как пункты делаются или становятся неактуальными.*
