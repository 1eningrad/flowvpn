# EclipVPN

Лёгкий VPN-менеджер для роутеров на OpenWrt. Заворачивает весь трафик через VPN, российские сайты идут напрямую. Поддерживает **VLESS / VMess / Trojan / Shadowsocks** (через xray) и **Hysteria2** (нативно через sing-box), несколько подписок одновременно.

[English](#english) | **Русский**

![EclipVPN UI](screenshots/dark.png)

> **Имя**: продукт для пользователя называется **EclipVPN** (бренд, UI, URL `/eclipvpn/`). Внутренние пути и команды CLI остались `eclipvpn` исторически — миграция backend ничего полезного не даёт, только риск что-то сломать.

## Возможности

- **Два режима маршрутизации**: «Всё через VPN кроме РФ» / «Только заблокированные»
- **Несколько протоколов**: VLESS (Reality/TLS; транспорты XHTTP / TCP+Vision / WS / gRPC), VMess, Trojan, Shadowsocks — через xray-core 26.4.17+; **Hysteria2** — нативным outbound'ом sing-box (QUIC, нужен `with_quic`)
- **sing-box tproxy** маршрутизация с geosite-ru / geoip-ru
- **Защита DNS**: перехват DNS, блокировка DoT и QUIC от подмены провайдером
- **Веб-интерфейс**: тёмная тема, glassmorphism, русский язык, mobile-friendly
- **Несколько подписок сразу**: серверы со всех включённых провайдеров сливаются в один список (с меткой провайдера); формат подписки — base64 или JSON, авто-определение; имя подписки берётся из самой подписки (заголовок `Profile-Title`)
- **Серверы**: параллельный пинг с retry+ICMP fallback; список группируется по провайдеру, группы можно сворачивать, длинный список крутится в рамке
- **Маршрутизация по устройствам**: VPN или Direct для каждого устройства в LAN
- **Скорость в реальном времени**: через Clash API WebSocket
- **Авто-переключение**: watchdog меняет сервер при сбое (тарифицируемые операторы исключаются)
- **Без утечек DNS**: при переключении nftables и dnsmasq остаются на месте — fail-closed, не direct
- **История сбоев**: таймаут проверок, авто-переключения, неудачные ручные смены — отдельный фильтр в журнале с бейджами «⚠ N» возле проблемных серверов
- **Учёт трафика**: per-chain (через VPN / напрямую), переживает рестарты sing-box, ручной сброс через UI
- **Журнал**: три источника (EclipVPN / sing-box / xray), фильтры с подсказками, экспорт в txt
- **Расписание**: cron включения/выключения по времени
- **Бэкап**: экспорт/импорт настроек как JSON
- **Диагностика**: автоматические проверки + healthcheck (xray, sing-box, nft, DNS, утечки IP)

## Требования

- Роутер с OpenWrt 23+ (тестировано на Routerich AX3000, aarch64)
- 256 MB+ RAM, 40 MB+ свободной flash
- Доступ в интернет для xray-core и списков доменов

## Быстрая установка

> **Репозиторий приватный.** Публичный `curl | sh` ниже сработает только у тех, у кого есть доступ к репо (или если сделать его публичным). Способы установки сейчас: **Windows-установщик** (см. ниже), приватный `curl` с PAT, либо `install-from-mac.sh` из локальной копии.

**Если репозиторий публичный:**
```bash
ssh root@router-ip
curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
```

**Если приватный** — нужен fine-grained Personal Access Token (read-only `Contents` на этом репо). Заголовок — в двойных кавычках (в одинарных `$REPO_TOKEN` не раскроется), и токен надо явно пробросить в окружение `sh`, читающего скрипт из пайпа:
```bash
ssh root@router-ip
REPO_TOKEN=ghp_xxxxx
curl -sSL -H "Authorization: Bearer $REPO_TOKEN" \
  https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh \
  | REPO_TOKEN="$REPO_TOKEN" sh
```

Установщик ставит зависимости, скачивает xray под архитектуру, кладёт скрипты и UI в правильные пути, создаёт redirect со старого `/flowvpn/` на `/eclipvpn/`.

## Windows-установщик (офлайн `.exe`)

Для тех, кто не хочет возиться с SSH/curl вручную: **`EclipVPN-Installer.exe`** — самодостаточный офлайн-установщик под Windows. Ставит EclipVPN на роутер по SSH из графического окна (EN/RU, авто-поиск роутера по шлюзу + SSH-скан). Полностью офлайн — внутри зашиты xray, sing-box, jq, curl, CA-bundle (aarch64) и код роутера, так что доступ к GitHub/apk **с роутера не нужен** (актуально, когда GitHub в RU заблокирован).

Скачивается из релиза:

- **Релиз**: [`v2026.06`](https://github.com/1eningrad/flowvpn/releases/tag/v2026.06)
- **Файл**: `EclipVPN-Installer.exe` (~31 МБ, aarch64)
- **SHA-256**: `9d5563a5844c3bf7daf2ee8396c2b9470604dc8137f7c0054b208eba4693f1ec`

> Поскольку репозиторий приватный, ассет качается **только с авторизацией** в GitHub: открой страницу релиза в браузере, где ты залогинен, и нажми на файл (прямая ссылка `releases/download/...` без авторизации отдаёт 404). Либо из CLI с доступом: `gh release download v2026.06 -R 1eningrad/flowvpn`.

Пересборка после изменений в `usr/`/`www/`/`etc/`: `cd windows-installer && powershell -ExecutionPolicy Bypass -File build-exe.ps1` (подробности — `windows-installer/README.md`).

## Ручная установка

```bash
# 1. Зависимости
opkg update
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box unzip

# 2. xray 26.4.17+ (НЕ из opkg — там старый 25.1.30 с багами XHTTP)
# Скачать с https://github.com/XTLS/Xray-core/releases, положить в /usr/bin/xray, chmod +x

# 3. Скопировать файлы
# usr/bin/eclipvpn           → /usr/bin/eclipvpn
# usr/lib/eclipvpn/*.sh      → /usr/lib/eclipvpn/
# www/cgi-bin/eclipvpn       → /www/cgi-bin/eclipvpn
# www/eclipvpn/index.html    → /www/eclipvpn/index.html  (новый путь)
# etc/init.d/eclipvpn        → /etc/init.d/eclipvpn

# 4. Права
chmod +x /usr/bin/eclipvpn /www/cgi-bin/eclipvpn /etc/init.d/eclipvpn /usr/lib/eclipvpn/*.sh

# 5. Настройка
eclipvpn sub add "https://your-subscription-url"   # имя возьмётся из подписки; повтори для нескольких провайдеров
eclipvpn start                                     # (sub add сам скачивает серверы)

# 6. Автозапуск
/etc/init.d/eclipvpn enable
```

## Веб-интерфейс

Откройте `http://router-ip/eclipvpn/`. Старая ссылка `/eclipvpn/` отдаёт meta-refresh redirect.

### Вкладки

| Вкладка | Описание |
|---|---|
| **Маршрутизация** | Режим работы, списки доменов (direct/VPN), DNS-настройки |
| **Устройства** | LAN-клиенты, переключение VPN/Direct по MAC |
| **Журнал** | Соединения в реальном времени. Фильтры: Все · VPN · Direct · Ошибки · Сбои · DNS · EclipVPN. Под фильтрами видна короткая подсказка что значит каждый. |
| **Диагностика** | Быстрые метрики (статус, IP, сервер, время) + healthcheck (статус процессов, DNS, утечки, ресурсы, ошибки) |
| **Настройки** | Подписки (несколько: добавить / вкл-выкл / переименовать / удалить, у каждой видно имя из панели и квоту), расписание, авто-обновление, бэкап |

## Команды CLI

```bash
eclipvpn start | stop | restart | status
eclipvpn set-server N                # Выбрать сервер по индексу (в общем списке всех подписок)
eclipvpn set-mode all_vpn|blocklist  # Режим маршрутизации
eclipvpn sub list                    # Список подписок
eclipvpn sub add URL [ИМЯ]           # Добавить подписку (имя возьмётся из Profile-Title, если не задано)
eclipvpn sub remove ID               # Удалить подписку (ID — из `sub list`)
eclipvpn sub enable ID | disable ID  # Включить / выключить подписку
eclipvpn sub rename ID ИМЯ           # Переименовать подписку
eclipvpn update                      # Обновить ВСЕ включённые подписки и правила
eclipvpn ping                        # Пинг всех серверов (TCP, retry, ICMP fallback)
eclipvpn real-ping                   # Реальная задержка через активный туннель, любой протокол (для отладки)
eclipvpn diagnose                    # Быстрая диагностика
eclipvpn healthcheck                 # Полная проверка (статус, DNS, утечки)
eclipvpn add-domain DOMAIN vpn       # Принудительно через VPN
eclipvpn add-domain DOMAIN direct    # Принудительно напрямую
eclipvpn get-log 50 all              # Просмотр логов
eclipvpn get-incidents               # История сбоев со статистикой по серверам
eclipvpn clear-incidents             # Очистить историю сбоев
eclipvpn reset-traffic               # Обнулить счётчики «Через VPN» / «Напрямую»
eclipvpn backup                      # Экспорт настроек
```

## Архитектура

```
Клиент → dnsmasq(:53) → sing-box DNS(:5354) → dns-proxy(VPN) / dns-direct
       → nftables tproxy → sing-box(:2154) → xray SOCKS(:1080) → VPN-сервер (VLESS/VMess/Trojan/SS)
                                            → direct (RU-сайты)
```

**Движок зависит от протокола сервера.** Для VLESS / VMess / Trojan / Shadowsocks набирает **xray** (он держит SOCKS на :1080, sing-box отдаёт ему трафик через `default`-outbound). Hysteria2 — это QUIC, xray его не умеет, поэтому **sing-box набирает его сам** нативным outbound'ом (и сам держит :1080); xray в этом случае не запускается. Переключение прозрачно: выбираешь сервер любого протокола из общего списка — нужный движок поднимается автоматически.

### Как работает маршрутизация

**Режим «Всё через VPN кроме РФ»:**
- Все DNS-запросы идут через VPN (защита от подмены)
- DNS для RU-доменов — напрямую (быстрее)
- geosite-ru + geoip-ru — тысячи российских доменов и IP → напрямую
- Всё остальное → через VPN-сервер
- DoT (порт 853) и QUIC (UDP 443) блокируются → приложения откатываются на обычный DNS / TCP

**Режим «По списку»:**
- Только домены из Shadowrocket-списка → через VPN
- Всё остальное → напрямую

## Важные нюансы

- **xray ≥ 26.4.17** — версия из opkg (25.1.30) ломает XHTTP+Reality
- **Hysteria2 требует sing-box с тегом `with_quic`** — это QUIC-протокол, набирается нативно через sing-box (не xray). В OpenWrt 25.12 пакетный sing-box собран с QUIC; проверить: `sing-box version | grep with_quic`. Если тега нет — hysteria2-серверы распарсятся, но не подключатся (в лог пишется явная причина).
- **mark 0x8000** — обязателен для обхода правил fw4
- **geosite-ru включает google.com** — Gemini / AI Studio добавляйте в «Принудительно через VPN» (часть AI-сервисов уже встроена в дефолтный список)
- **QUIC (UDP 443) блокируется** во всех режимах — приложения откатываются на TCP. Reject-правило стоит **до** force-VPN match'а, поэтому Gemini / ChatGPT по UDP не идут через VPN, а просто переходят на TCP. Это намеренно: QUIC поверх Reality+XHTTP нестабилен.
- **DNS-direct идёт на Яндекс 77.88.8.8** (UDP). Cloudflare 1.1.1.1 возвращал SERVFAIL для VTB и некоторых других банков — у них авторитетные NS отказываются обслуживать иностранных резолверов. Яндекс резолвит всё и отдаёт ближайшие RU-CDN. Под CGNAT'ом, который перехватывает UDP/53 (например SevenSky), резолв «direct»-доменов может ломаться — тогда RU-сайты будут открываться через VPN.
- **Datacenter-IP заблокированы у OpenAI / Anthropic / некоторых других AI-провайдеров.** Если ваш VPN-сервер у Hetzner / OVH / DigitalOcean — даже корректный маршрут даст 403. Решается только residential-IP сервером.
- **Время на роутере должно быть синхронизировано** — иначе Reality handshake падает (NTP при первом запуске)
- **Clash API доступен на `:9090` для всех на LAN.** Токен отдаётся UI через `/status`, любое устройство в той же Wi-Fi-сети может им воспользоваться. Подходит для модели «доверять домашнему LAN»; в публичном Wi-Fi не разворачивайте.

## Удалённый доступ к роутеру (RemoteRouteRich)

На прошивке Routerich есть встроенная штука для управления роутером из любой точки — **RemoteRouteRich**: самохостед Tailscale на серверах вендора. Работает под CGNAT, без белого IP, бесплатно. После настройки — SSH и web-UI EclipVPN всегда доступны по Tailscale-IP роутера (`100.x.y.z`).

```bash
# Включение через install.sh:
WITH_REMOTE=1 sh install.sh

# Или на уже установленном роутере:
ssh root@router-ip
opkg update && opkg install tailscale-lite luci-app-tailscale luci-i18n-tailscale-ru
uci set tailscale.settings.login_server='https://rc.routerich.ru/'
uci set tailscale.settings.enabled='1'
uci commit tailscale
/etc/init.d/tailscale enable && /etc/init.d/tailscale restart
sleep 4 && tailscale status   # покажет URL вида https://rc.routerich.ru/a/r/XXXX
```

Дальше:
1. Открыть выданный URL в браузере. Если tailnet ещё нет — создать на https://remote.routerich.ru/create-tailnet (один клик, выдаст имя сети и два ключа — **сохрани, показывают один раз, действуют 1 год**).
2. Поставить Tailscale-клиент на телефон/ноутбук, ввести то же имя tailnet и тот же `login_server`.
3. После подключения — `ssh root@<tailscale-ip>` и `http://<tailscale-ip>/eclipvpn/` работают из любой сети.

Нюансы:
- В RU App Store / Google Play клиент Tailscale **недоступен**. Вендор даёт APK и TestFlight-инвайт по ссылкам в [docs.routerich.ru/ru/remote](https://docs.routerich.ru/ru/remote).
- Hostname роутера не должен содержать `_` или `.` (только буквы/цифры/дефис) — иначе Tailscale откажется регистрироваться.
- Лимит — 2 tailnet'а в сутки с одного публичного IP.
- `accept_routes='0'` и `accept_dns='0'` оставляем как есть: иначе Tailscale полезет в DNS и в маршруты, что конфликтует с tproxy/перехватом DNS EclipVPN.

## Обновление существующей установки

```bash
# С исходников (одна команда):
cd ~/eclipvpn && ./deploy.sh                  # default root@192.168.1.1
ROUTER=root@10.0.0.1 ./deploy.sh             # другой роутер
# deploy.sh делает: git pull → tar-pipe всех скриптов/CGI/UI →
# ash -n syntax-check → init.d stop → wipe stale rules + watchdog
# state → kill orphan watchdogs → init.d restart → verification.

# Hard reload UI в браузере: Cmd+Shift+R / Ctrl+Shift+R
```

При первом запуске создаётся `/etc/eclipvpn/clash_secret` (32 hex, chmod 600) — токен Clash API. UI получает его через `/status`, ничего вручную не настраивается.

## Перенос на второй роутер

Сценарий: ставишь EclipVPN на ещё один роутер той же модели (например, Routerich AX3000) и хочешь чтобы все настройки — подписка, режим, расписание, device rules, кастомные direct/VPN-списки — приехали с первого без ручного перевоза.

### 1. На текущем роутере — бэкап

```bash
ssh root@192.168.1.1 'eclipvpn backup' > ~/eclip-config.json
```

(или в UI: Настройки → «Экспорт настроек» → скачается тот же JSON.)

### 2. На новом роутере — установка

**Если репозиторий приватный** (нет GitHub PAT под рукой) — используй `install-from-mac.sh`. Он tar-pipe'ит исходники из локальной копии репо, без обращения к GitHub:

```bash
# фабричный роутер (после reset, IP 192.168.1.1):
ROUTER=root@192.168.1.1 sh ~/eclipvpn/install-from-mac.sh

# уже переехавший на свой LAN-IP:
sh ~/eclipvpn/install-from-mac.sh   # default: root@192.168.2.1
```

Скрипт делает ровно то же что `install.sh` — opkg deps + xray 26.4.17 + Tailscale (RemoteRouteRich) + автозапуск — но файлы EclipVPN заливает из локальной копии репозитория. Подходит когда нет токена либо новый роутер не имеет внешнего интернета (например, через переходник USB-C → Ethernet напрямую к Mac, без выхода в WAN на этом этапе).

**Если репо публичный или есть PAT** — используй `install.sh` через curl как описано в шапке `install.sh`.



> **Подсказка**: фабричный IP у Routerich тоже `192.168.1.1`. Если оба роутера одновременно в одной подсети — конфликт. Подключай новый отдельным кабелем или сразу меняй ему IP в LuCI.

```bash
ssh root@<new-router-ip>
WITH_REMOTE=1 sh -c "$(curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh)"
```

`WITH_REMOTE=1` опционален — добавляет шаг с RemoteRouteRich (Tailscale). Установщик сам поставит зависимости, скачает xray 26.4.17, развернёт UI, поднимет Tailscale-демона и выдаст URL для авторизации.

### 3. Подключение в существующий tailnet

Не создавай новый tailnet — используй тот же, что и на первом роутере, чтобы оба были видны друг другу и с твоих клиентов.

1. Открой `http://remote.routerich.ru/login`, вставь свой management_key.
2. В админке выпусти **новый Device Auth Key** (старые single-use, текущий первый роутер уже занял).
3. Открой URL для авторизации, который выдал установщик на шаге 2, и подставь туда новый ключ. Либо на новом роутере: `tailscale up --login-server=https://rc.routerich.ru/ --authkey=<new-key>`.

После этого `tailscale status` на любом устройстве в тайнете покажет оба роутера. SSH/UI любого — по их `100.x.y.z`.

### 4. Импорт настроек

```bash
scp ~/eclip-config.json root@<new-router-ip>:/tmp/
ssh root@<new-router-ip> 'eclipvpn restore < /tmp/eclip-config.json'
```

Или через UI: Настройки → «Восстановить из файла» → выбрать `eclip-config.json`.

### 5. Автозапуск

```bash
ssh root@<new-router-ip> '/etc/init.d/eclipvpn enable'
```

### Проверка

Открой UI нового роутера `http://<new-router-ip>/eclipvpn/`. Подписка, серверы, режим, расписание должны быть на месте. На вкладке «Диагностика» — все галочки зелёные.

### Что НЕ переносится бэкапом

- `clash_secret` — пересоздаётся автоматически при первом запуске.
- `/tmp/eclipvpn/*` (servers.json, traffic_state.json, incidents.json) — нормально, это runtime-state, восстанавливается из подписки и обнуляется по факту.
- Tailscale-сертификат tailnet — он на устройство, не на конфиг EclipVPN.

## Решение проблем

1. **Сайт не открывается** → Журнал → фильтр «DNS» (резолвится ли) и «Direct/VPN» (куда идёт)
2. **Приложение пишет «нет сети»** → авиарежим вкл/выкл, либо `eclipvpn restart`
3. **«Не поддерживается в вашей стране»** → добавьте домен в «Принудительно через VPN»
4. **Сервер мерцает** → бейдж «⚠ N» в списке серверов + история в Журнале → фильтр «Сбои»
5. **Сломался WAN** → `ssh root@router` → `eclipvpn stop` → проверить интернет на роутере отдельно

## Документация

- [docs/eclipvpn_manual.pdf](docs/eclipvpn_manual.pdf) — подробный мануал (PDF, RU)
- [docs/ROADMAP.md](docs/ROADMAP.md) — план развития

Сборка PDF: `cd docs && tectonic eclipvpn_manual.tex` ([tectonic](https://tectonic-typesetting.github.io/))

## Ресурсы

- **RAM**: ~112 MB (xray 64 + sing-box 46)
- **Flash**: ~33 MB (xray 32.5 + скрипты 112 KB)
- **CPU**: ~0% (Reality на aarch64 очень лёгкий)

---

<a name="english"></a>
## English

Lightweight VPN manager for OpenWrt routers. Russian sites bypass the tunnel. Supports VLESS / VMess / Trojan / Shadowsocks (via xray) and Hysteria2 (native sing-box outbound), with several provider subscriptions merged into one server list.

### Quick install

> The repository is **private**, so the public `curl | sh` below only works for users with repo access (or if you make it public). Options: the **Windows installer** (`EclipVPN-Installer.exe`, from the [`v2026.06` release](https://github.com/1eningrad/flowvpn/releases/tag/v2026.06) — a fully offline GUI installer; the download itself needs GitHub auth), the private-PAT curl below, or `install-from-mac.sh`.

Public repo:
```bash
curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
```

Private repo (fine-grained PAT, read-only `Contents`; double quotes matter — single quotes would send the literal string `$REPO_TOKEN` — and the token must be re-exported into the piped `sh`):
```bash
REPO_TOKEN=ghp_xxxxx
curl -sSL -H "Authorization: Bearer $REPO_TOKEN" \
  https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh \
  | REPO_TOKEN="$REPO_TOKEN" sh
```

See the Russian section above for full documentation.

## License

MIT
