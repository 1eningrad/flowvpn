# FlowVPN

Легковесный VPN-менеджер для роутеров на OpenWrt. Направляет весь трафик через VPN (VLESS+XHTTP+Reality), российские сайты идут напрямую.

[English](#english) | **Русский**

![FlowVPN UI](screenshots/dark.png)

## Возможности

- **Два режима маршрутизации**: Всё через VPN (кроме RU) / Только заблокированные
- **VLESS+XHTTP+Reality** через xray-core 26.4.17+
- **sing-box** tproxy маршрутизация с geosite-ru/geoip-ru
- **Защита DNS**: перехват DNS, блокировка DoT/QUIC для предотвращения подмены провайдером
- **Веб-интерфейс**: тёмная/светлая тема, русский язык
- **Управление серверами**: импорт подписки, пинг, ручной выбор
- **Маршрутизация по устройствам**: VPN или Direct для каждого устройства
- **Скорость в реальном времени**: через Clash API WebSocket
- **Авто-переключение**: watchdog переключает сервер при сбое
- **Диагностика**: 25 автоматических проверок
- **Журнал**: три источника (FlowVPN/sing-box/xray), фильтры, экспорт
- **Расписание**: включение/выключение по времени
- **Бэкап**: экспорт/импорт настроек

## Требования

- Роутер с OpenWrt (протестировано на Routerich AX3000, aarch64)
- 256MB+ RAM, 40MB+ свободной flash-памяти
- Доступ в интернет для загрузки xray и списков доменов

## Быстрая установка

```bash
ssh root@ваш-роутер
curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
```

## Ручная установка

```bash
# 1. Установить зависимости
opkg update
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box

# 2. Установить xray 26.4.17+ (НЕ из opkg — там старая версия)
# Скачайте с https://github.com/XTLS/Xray-core/releases
# Загрузите на роутер в /usr/bin/xray

# 3. Скопировать файлы FlowVPN
# usr/bin/flowvpn           → /usr/bin/flowvpn
# usr/lib/flowvpn/          → /usr/lib/flowvpn/
# www/cgi-bin/flowvpn       → /www/cgi-bin/flowvpn
# www/flowvpn/index.html    → /www/flowvpn/index.html
# etc/init.d/flowvpn        → /etc/init.d/flowvpn

# 4. Установить права
chmod +x /usr/bin/flowvpn /www/cgi-bin/flowvpn /etc/init.d/flowvpn /usr/lib/flowvpn/*.sh

# 5. Настроить
flowvpn set-config subscription_url "https://ваша-подписка"
flowvpn update
flowvpn start

# 6. Включить автозапуск
/etc/init.d/flowvpn enable
```

## Веб-интерфейс

Откройте `http://ip-роутера/flowvpn/` в браузере.

### Вкладки

| Вкладка | Описание |
|---------|----------|
| **Маршрутизация** | Режим работы, списки доменов (direct/VPN), DNS настройки |
| **Устройства** | Подключённые устройства, переключение VPN/Direct для каждого |
| **Журнал** | Соединения в реальном времени с фильтрами (VPN/Direct/DNS/Ошибки) |
| **Диагностика** | Полная проверка системы (25 тестов) и быстрая диагностика |
| **Настройки** | Подписка, расписание, автообновление, бэкап |

## Команды CLI

```bash
flowvpn start|stop|restart|status
flowvpn set-server N              # Выбрать сервер по индексу
flowvpn set-mode all_vpn|blocklist # Режим маршрутизации
flowvpn update                    # Обновить подписку и правила
flowvpn ping                      # Пинг всех серверов
flowvpn diagnose                  # Быстрая диагностика
flowvpn healthcheck               # Полная проверка (25 тестов)
flowvpn add-domain DOMAIN vpn     # Принудительно через VPN
flowvpn add-domain DOMAIN direct  # Принудительно напрямую
flowvpn get-log 50 all            # Просмотр логов
flowvpn backup                    # Экспорт настроек
```

## Архитектура

```
Клиент → dnsmasq(:53) → sing-box DNS(:5354) → dns-proxy(VPN) / dns-direct
       → nftables tproxy → sing-box(:2154) → xray SOCKS(:1080) → VPN сервер
                                            → direct (RU сайты)
```

### Как работает маршрутизация

**Режим "Всё через VPN":**
- Все DNS-запросы идут через VPN (защита от подмены провайдером)
- DNS для RU-доменов — напрямую (быстрее)
- geosite-ru + geoip-ru — тысячи российских доменов и IP → напрямую
- Всё остальное → через VPN-сервер
- DoT (порт 853) и QUIC (UDP 443) блокируются → приложения используют обычный DNS

**Режим "По списку":**
- Только домены из списка Shadowrocket → через VPN
- Всё остальное → напрямую

## Важно

- **xray должен быть 26.4.17+** — версия из opkg (25.1.30) имеет критические баги с XHTTP
- **mark 0x8000 (32768)** — обязателен для обхода fw4 firewall
- **geosite-ru включает google.com** — сервисы Google AI (Gemini) нужно добавить в принудительный VPN
- **QUIC (UDP 443) блокируется** в режиме "Всё через VPN" — приложения переключаются на TCP

## Решение проблем

1. **Сайт не открывается** → Журнал → проверьте идёт ли трафик через VPN или Direct
2. **Приложение пишет "нет сети"** → Авиарежим вкл/выкл на телефоне
3. **AI-сервис пишет "не поддерживается в вашей стране"** → Добавьте домен в "Принудительно через VPN"
4. **Всё сломалось** → Диагностика → Запустить проверку
5. **Нет интернета** → `ssh root@роутер` → `flowvpn stop`

## Ресурсы

- **RAM**: ~112 MB (xray 64MB + sing-box 46MB)
- **Flash**: ~33 MB (xray 32.5MB + скрипты 112KB)
- **CPU**: ~0% (шифрование Reality на aarch64 очень лёгкое)

---

<a name="english"></a>
## English

Lightweight VPN manager for OpenWrt routers. Routes all traffic through VPN (VLESS+XHTTP+Reality), Russian sites go direct.

### Quick Install

```bash
ssh root@your-router
curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
```

See Russian section above for full documentation.

## License

MIT
