# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Brand vs. internals

User-facing brand is **EclipVPN**. As of release **2026.06** the internals were renamed `flowvpn` → `eclipvpn` as well: CLI `/usr/bin/eclipvpn`, libs `/usr/lib/eclipvpn/`, config `/etc/eclipvpn/`, runtime tmp `/tmp/eclipvpn/`, service `/etc/init.d/eclipvpn`, CGI `/www/cgi-bin/eclipvpn`, nft tables `eclipvpn`/`eclipvpn_dns`, logger tag `eclipvpn`, shell vars `$ECLIPVPN_*`, and the version constant `ECLIPVPN_VERSION` in `usr/bin/eclipvpn`.

Two things deliberately **stay `flowvpn`** — do not rename them:
- The **GitHub repo** `1eningrad/flowvpn` (the `install.sh` raw-URL and the UI footer links point at it; renaming the URL 404s the installer). Rename the repo on GitHub first if you want these to change.
- The **legacy `/www/flowvpn/` → `/eclipvpn/` redirect** stub (created by the installers) for old bookmarks.

`install.sh` / `install-from-mac.sh` / `deploy.sh` carry a one-time, idempotent **migration**: on a router with an old `flowvpn` install they stop+disable the old service, kill its watchdog (matched by the start-anchored cmdline `"/bin/ash /usr/bin/flowvpn watchdog"*`), clean its nft tables + dnsmasq drop-in, `mv /etc/flowvpn /etc/eclipvpn` (preserving subscription/settings), and remove the old files.

## What this is

A VPN manager for OpenWrt routers. Written almost entirely in **busybox ash** (`#!/bin/ash`, not bash) with a single-file HTML/JS web UI. Two binaries do the actual work: **xray** (SOCKS outbound, VLESS+XHTTP over either **Reality** *or* plain **TLS**) and **sing-box** (tproxy inbound, DNS, routing). Everything else is glue. The TLS variant is what powers **CDN fronting** — `xray.sh` switches on the subscription entry's `security` field (`reality` → `realitySettings`, `tls` → `tlsSettings`), so a server can front through a CDN (`sni=*.selcdn.net`) to dodge the per-flow policer (see "CDN fronting" below).

There is no build step, no package manager, no CI for the router code. Code is shipped to a live router via `deploy.sh`. (The Windows installer under `windows-installer/` is the one piece with a build step — see its section below.) There **is** a unit-test suite (`tests/`, added 2026-06-16) covering the pure parsers, input validators, and the lock / config-write primitives — see "Testing" below.

## Common commands

| Command | What it does |
| --- | --- |
| `./deploy.sh` | Push current tree to `root@192.168.1.1`. tar-pipes the scripts/CGI/UI, syntax-checks with `ash -n`, force-cleans stale watchdog/rules state, restarts via init.d, prints verification. |
| `ROUTER=root@10.0.0.1 ./deploy.sh` | Same, against a different router. |
| `./install.sh` | One-shot installer (run *on the router*) — installs deps, fetches xray 26.4.17 binary, writes files to canonical paths. |
| `sh install-from-mac.sh` | Bootstrap a *fresh* router from the local tree over SSH (default `root@192.168.2.1`), bypassing the GitHub repo — pushes the same files as `install.sh` but from the working tree. Use for first-time provisioning / after a factory reset; `deploy.sh` is for updating an already-installed router. `WITH_REMOTE=0` skips the Tailscale step. |
| `ash -n <file>` | Syntax-check a script before deploy. `deploy.sh` already runs this on every shell file. |
| `sh tests/run.sh [suite...]` | Run the unit suite (needs `jq`). No args = all; `parse`/`validators`/`locks`/`config` = one suite. Exit non-zero on any failure. See "Testing". |
| `cd docs && tectonic eclipvpn_manual.tex` | Rebuild the user manual PDF. |
| `cd windows-installer && powershell -ExecutionPolicy Bypass -File build-exe.ps1` | Rebuild `EclipVPN-Installer.exe` (offline Windows installer). Stages the live `usr/`/`www/`/`etc/` tree — rebuild after any router-code change. See its own section below. |

### Testing

`tests/run.sh` is a small ash+jq unit suite (added 2026-06-16) — the first automated net for ~6k lines of shell. It sources the REAL code (`usr/bin/eclipvpn` with `ECLIPVPN_SOURCE_ONLY=1`, which stops before init/the dispatch case) against a scratch `ECLIPVPN_TMP`/`ECLIPVPN_CONFIG`, so tests call the actual functions — no copies. The three path vars (`ECLIPVPN_LIB`/`ECLIPVPN_CONFIG`/`ECLIPVPN_TMP`) are overridable for exactly this reason; production passes none, so defaults are unchanged. Suites: `test_parse.sh` (proxy-URL + subscription-body parsers, `url_decode`, `_b64_pad`), `test_validators.sh` (`_validate_ipv4`, `_normalize_mac`, engine helpers, `_is_metered_server`), `test_locks.sh` (`_op_begin` TOCTOU + `_config_lock`), `test_config.sh` (`update_config` RMW, concurrency, backup rotation). 89 assertions as of the first cut.

Run on the dev box if `jq` is present (`sh tests/run.sh`); the Windows box has no `jq`, so run on the router: `tar c usr tests | ssh root@ROUTER 'rm -rf /tmp/eclvt && mkdir -p /tmp/eclvt && cd /tmp/eclvt && tar x && sh tests/run.sh'`. `tests/` is NOT shipped by `deploy.sh`/installers — it's dev-only. Still verify runtime/UI behaviour with `./deploy.sh` + the UI; the suite covers the pure/lock logic, not the live tunnel. The `test-results/` dir is unrelated (old screenshots).

For UI changes, hard-reload in the browser (`Cmd+Shift+R`) — the CGI sends no-cache headers but the static `index.html` is cached aggressively.

## CLI surface (existing commands)

Top-level user commands already implemented in `usr/bin/eclipvpn` — check here before adding a new one:

```
start | stop | restart [force] | status  lifecycle (restart 1 = force past unchanged-config no-op)
set-server N                             pick server by index (index into the MERGED multi-sub pool)
probe-server N                           probe a server (throwaway engine — xray, or sing-box dialer for hysteria2) without touching live tunnel
sub list|add URL [NAME]|remove ID        manage multiple provider subscriptions (config.subscriptions[])
sub enable ID|disable ID|rename ID NAME  toggle / rename a subscription (ID = md5-8 of its URL)
set-mode all_vpn|blocklist               routing mode
update                                   refresh ALL enabled subscriptions (merge) + RU/blocklist domain rules
auto-select | auto-eval                  pick fastest server by probe / re-evaluate live server health
ping | real-ping                         TCP probe (with ICMP fallback) / VLESS-Reality probe
diagnose | healthcheck                   quick metrics / full check (DNS, leaks, processes)
system-info                              firmware + xray/sing-box versions, uptime, resources
add-domain DOM vpn|direct                add to user override list
remove-domain DOM vpn|direct             remove from user override list
get-domains                              dump custom + built-in vpn/direct lists
preset list|enable|disable NAME          bundled domain presets (defined in singbox.sh)
get-devices                              DHCP-lease clients (for per-device routing)
set-device ID vpn|direct                 per-device route override (id = ip or mac)
remove-device ID                         clear a per-device override
get-dns                                  current dnsmasq upstream + mode
set-config KEY VALUE                     write a whitelisted config.json key
set-wifi SSID PASSWORD                   change router Wi-Fi via uci
schedule set ON OFF | disable | get      timed auto on/off window
auto-update enable|disable|status        nightly subscription/rules refresh
get-log N FILTER | clear-log             tail logs (filter: all|vpn|direct|error|dns|flow) / reset tail
get-traffic | traffic-poll               per-outbound byte accounting / live up-down sample (Clash API)
get-incidents | clear-incidents          failover history
reset-traffic                            zero per-chain byte counters
backup | restore JSON                    export / import config as JSON
watchdog                                 internal — single-instance, do not call directly
ensure-watchdog                          internal — cron-driven watchdog revival (*/5, gated on running_intent)
```

CGI surface is dispatched via query string in `www/cgi-bin/eclipvpn` and covers almost the same set — exceptions: `get-dns`, `set-wifi`, `auto-eval` are CLI-only (no CGI action), and `diagnose`/`real-ping` are exposed via CGI but not called by the UI.

## Code layout

```
usr/bin/eclipvpn              CLI dispatcher (~400 lines): init, the dispatch case,
                              core helpers (get_config_val/flog/save_config/_op_*/
                              _rotate_log/_ensure_watchdog) and the shared incident
                              helpers (_is_metered_server/_record_switch/_log_incident)
usr/lib/eclipvpn/parse.sh     PURE parsers: vless/vmess/trojan/ss/hysteria2 URLs
                              + base64/JSON subscription bodies → server objects
usr/lib/eclipvpn/subscriptions.sh  multi-provider fetch + merge + `sub` mgmt
                              (fetch_subscription/update_subscription/_remap/cmd_sub
                              /_migrate_subscriptions); was split out of parse.sh+config
usr/lib/eclipvpn/xray.sh      xray config gen + start/stop/test
usr/lib/eclipvpn/singbox.sh   sing-box config gen, RU domain list, blocklist sources
usr/lib/eclipvpn/network.sh   nftables + dnsmasq redirect setup/teardown
usr/lib/eclipvpn/watchdog.sh  connectivity probing, auto-failover, throughput guard
usr/lib/eclipvpn/lifecycle.sh cmd_start / stop / restart / status
usr/lib/eclipvpn/servers.sh   set-server / probe / update / ping / auto-select + auto-eval
usr/lib/eclipvpn/domains.sh   routing mode, custom domain lists, service presets
usr/lib/eclipvpn/traffic.sh   Clash-API traffic accounting (get-traffic/poll/real-ping/reset)
usr/lib/eclipvpn/health.sh    devices / logs / dns / diagnose / incidents / healthcheck / system-info
usr/lib/eclipvpn/config.sh    set-config / schedule / auto-update / backup-restore / device-routing / wifi
www/cgi-bin/eclipvpn          CGI shim: query-string → CLI dispatch (+ anti-CSRF/rebinding gate)
www/eclipvpn/index.html       Single-file SPA UI (installs to /www/eclipvpn/index.html)
etc/init.d/eclipvpn           OpenWrt service stub (autostart-on-boot)
deploy.sh / install.sh       Rollout scripts
```

Library scripts are sourced into `usr/bin/eclipvpn` (the `. "$ECLIPVPN_LIB/*.sh"` block at the top) — they share global vars (`$ECLIPVPN_TMP`, `$ECLIPVPN_CONFIG`, `$SR_RULES_DIR`, etc.) and helpers (`flog`, `get_config_val`, `save_config`). The libs only *define* functions — no top-level code — and every cross-lib call resolves at invocation time, so **source order among them does not matter**. The dispatcher was split out of a single ~2900-line file (2026-06); a new `cmd_*` goes in the matching domain lib (or stays in the dispatcher only if it's core/shared infra), and the dispatch case at the bottom of `usr/bin/eclipvpn` is wired the same way regardless.

## Runtime data flow

```
LAN client → dnsmasq:53 → sing-box DNS:5354 → DoH 1.1.1.1:443 (via VPN) or UDP Yandex 77.88.8.8 (direct)
LAN client → nftables tproxy:2154 → sing-box → xray SOCKS:1080 → VLESS+Reality (VPN)
                                              ↘ direct (RU geosite/geoip + custom direct list)
```

- **mark 0x1** = packet entered tproxy, route via local table 100
- **mark 0x8000** = sing-box/xray's own outbound — anti-loop bypass at the top of `eclipvpn` nft chain
- **DoT (853)** and **QUIC (UDP 443)** are unconditionally rejected so apps fall back to plain DNS / TCP that we control

## Two routing modes

- `all_vpn` — everything → VPN, *except* domains/IPs in `geosite-ru`, `geoip-ru`, and the manual RU list in `singbox.sh::_fetch_ru_domains()` (Yandex/VK/Sber/etc).
- `blocklist` — only blocked domains → VPN; everything else direct. Source is `itdoginfo/allow-domains` (curated, ~1.2k) or `1andrevich/Re-filter-lists` (~80k) when `blocklist_source=full`.

A **force-VPN list** (`vpn_domains.list`, built-in AI services **+ YouTube** + user's `custom_vpn`) overrides the RU rules in `all_vpn` mode — gemini.google.com / youtube.com etc. would otherwise hit `geosite-ru` (which contains `google.com`). YouTube is in the built-in heredoc (`singbox.sh::_fetch_vpn_domains`) so every fresh install routes it through the VPN by default (it's throttled on RU networks); there is also a toggleable `youtube` service preset, but the built-in entry is the always-on baseline.

## CDN fronting & subscription formats

- **The throttle is a per-flow policer.** The RU-side TSPU pins flows to foreign *hosting* prefixes to ~60-90 KB/s in the evenings, per-TCP-connection (some flows escape), protocol-agnostic (raw TLS shaped the same as VLESS). The watchdog throughput guard (re-dial / switch) only buys minutes against it. The **real** mitigation is **CDN fronting**: the panel serves Selectel-CDN-fronted servers (UI label `🌐 Обход…`, `security=tls`, `sni=*.selcdn.net`) as ordinary subscription entries. They ride a clean CDN prefix the policer doesn't shape. `xray.sh` builds `security=tls` xhttp+tls outbounds for them (not just Reality), so they parse *and* connect like any other server.
- **`_is_metered_server`** (in `usr/bin/eclipvpn`) skips the `Обход` CDN servers so auto-select / failover prefer them.
- **`parse.sh` auto-detects the subscription format.** The same URL may return base64-of-proxy-URL-lines (most panels), URL-safe base64, plaintext, *or* a JSON array/object. Detection runs `jq -e 'type=="array" or type=="object"'` on the raw body *before* the base64 cascade — a JSON body must not be fed through `base64 -d` (which would silently corrupt it). **Busybox `tr` gotcha:** the router's busybox does **not** implement the POSIX `[:space:]` class, so `tr -d '[:space:]'` deletes the *literal* characters `[ : s p a c e ]` and corrupts any base64 containing them (it ate the `c` from a Shadowsocks userinfo, 2026-06-15). Strip whitespace by feeding `tr` the actual bytes: `tr -d "$(printf '\n\r\t ')"` (see `_b64_pad`). Do not "simplify" it back to the class form.
- **Multiple proxy protocols.** `parse.sh` parses `vless://` / `vmess://` (base64-JSON) / `trojan://` / `ss://` (SIP002 + legacy) / `hysteria2://` (+ `hy2://` alias) via a `parse_proxy_url` dispatcher into a uniform server object with a `protocol` discriminator (absent ⇒ `vless`) plus per-protocol credential fields (`hysteria2` uses `password`/`obfs`/`obfs_pw`/`insecure`). `xray.sh::generate_xray_config` branches on `protocol` (vless/vmess/trojan/shadowsocks). The vless branch selects `streamSettings` by `.transport` — `xhttp`/empty, `ws`, `grpc`, or raw `tcp` (the last carries `flow=xtls-rprx-vision` for VLESS-Reality-Vision); Reality stays vless-only. The **`xhttp` sub-branch is kept byte-identical** to the pre-multi-protocol generator so an existing eclip-sub servers.json (all xhttp+reality) regenerates the same `xray.json` (the `cmd_restart` unchanged-config fast path depends on it; verify with a `cmp` of old vs new xray.json for the selected server — proven identical incl. the xmux `extra` merge). The UI shows a small protocol badge (`/status` exposes `protocol`, never credentials). TUIC/WireGuard are still unsupported (parse.sh counts them as unknown and warns).
- **Proxy-engine abstraction (multi-protocol routing).** A server's `protocol` decides which binary dials the exit, via four helpers in `usr/bin/eclipvpn`: `_engine_for_protocol` (→ `"xray"` or `"singbox"`), `_server_protocol IDX`, `_selected_engine`, and `_vpn_running`. vless/vmess/trojan/shadowsocks → **xray** (the shared SOCKS:1080 frontend; sing-box's `default` outbound is socks→xray). **hysteria2 → sing-box NATIVE** (QUIC; xray can't speak it): `singbox.sh::_singbox_proxy_outbound` builds a `type:"hysteria2"` `default` outbound (with `routing_mark:32768` to bypass the tproxy anti-loop), sing-box ALSO opens its own SOCKS:1080 inbound, and a `{"inbound":["socks-in"],"outbound":"default"}` route rule pins that inbound to the tunnel so probes measure it in **both** modes. xray is not launched at all for a hysteria2 server. **`_vpn_running` REPLACES the old bare `is_xray_running && is_singbox_running`** everywhere (lifecycle/servers/domains/config/watchdog/health) — using `is_xray_running` on a hysteria2 server reads "down" forever (xray never runs), which would loop the watchdog reviver and show the VPN as stopped. `lifecycle.sh::_tunnel_bringup` is the shared start path (engine-aware; pre-flights `sing-box version | grep with_quic` for hysteria2). Probe/failover (`cmd_probe_server`, `_watchdog_probe_candidate`) build a throwaway config via `singbox.sh::_gen_probe_config` (echoes the engine; xray ⇒ `run -config`, sing-box ⇒ `run -c`) — a hysteria2 candidate spins up a throwaway sing-box dialer instead of a throwaway xray. Cheap RTT pre-filter (`servers.sh::_reach_ms`) uses ICMP for hysteria2 (UDP — no TCP :443 to connect to); `system-info` exposes `singbox_quic`. **All probe/health paths still curl 127.0.0.1:1080** unchanged — whichever engine is active owns that port.
- **Multiple subscriptions (merge-flat-with-tags).** `config.subscriptions[]` holds N providers `{id,name,url,enabled}` (`id` = md5-8 of the URL ⇒ adding the same URL twice is idempotent). `parse.sh::update_subscription` fetches every *enabled* sub into its OWN cache `sub.<id>.servers.json` (fetch-then-swap PER sub: a blocked/failed panel keeps its last servers), tags each server `sub_id`/`sub_name`, and concatenates them (config order) into ONE flat `servers.json`. **The whole index-based engine is therefore unchanged** — `selected_server` is still a flat index, set-server/auto-select/failover/probe/traffic/incidents all operate on the merged array. `cmd_sub` (config.sh) is the manager (list/add/remove/enable/disable/rename); `set-config subscription_url` delegates to `cmd_sub add` (back-compat). **`_remap_selected_server`** pins the user's selection across a rebuild by IDENTITY (protocol+host+port+name), not raw index — so adding/removing/reordering a sub doesn't silently switch the active server (and fixes the latent single-provider reorder bug). One-time `_migrate_subscriptions` (in `usr/bin/eclipvpn`, run at init) converts a legacy single `subscription_url` into `subscriptions[0]`. The UI (Settings ▸ Подписки) renders entirely from `/status` (which now returns `subscriptions` + keyed `subscription_meta` + `sub_id`/`sub_name` on each server) — no extra round-trip; the server list shows provider group headers only when >1 sub is active. Degenerate case: disabling/removing the LAST working sub leaves `servers.json` at its last-known pool (the count>0 swap guard protects a running tunnel) — the disabled provider's servers stay listed until a working sub exists again.

## Files and persistence

- `/etc/eclipvpn/config.json` (chmod 600) — sole config file. `subscriptions` (array of `{id,name,url,enabled}` — the multi-provider list), `subscription_url` (legacy single URL, kept mirrored to `subscriptions[0]` for back-compat), mode, `auto_start`, `auto_mode`, `running_intent`, `device_rules`, `schedule`, `selected_server`. Always write atomically via `save_config` (validates with `jq '.'` then `mv`). `save_config` also keeps 3 rolling backups (`config.json.1..3`, newest first) — rotated only when something *other than* the volatile keys (`selected_server`, `running_intent`) changes, so failover nights don't flush the history. Recovery: `cp config.json.1 config.json && eclipvpn restart 1`.
- `/etc/eclipvpn/clash_secret` (chmod 600) — 32-hex Clash API token, lazily created by `_get_clash_secret`. Never leaves the router: clash_api binds to 127.0.0.1, and the UI gets traffic/delay data through the CGI (`traffic-poll`, `get-traffic`, `real-ping`) which uses the secret server-side.
- `/etc/eclipvpn/hwid` (chmod 600) — stable per-router UUID, lazily minted by `_get_hwid` (parse.sh). Sent as `X-HWID` (+ `X-Device-OS/Ver/Model`, custom `User-Agent`) on every subscription fetch via `_sub_curl` for the panel's device-binding/HWID limit. Device-specific: deliberately excluded from `backup`/`restore` so it isn't cloned onto another router.
- `/etc/eclipvpn/{direct,vpn}_domains.txt` — user's custom domain lists (one per line).
- `/etc/eclipvpn/rules/` — cached sing-box `.srs` rule sets (`geosite-category-ru.srs`, `ru.srs`). Persisted (not in /tmp) because raw.githubusercontent.com is often blocked from inside RU: an existing cache wins over a re-download unless forced, and if there's no cache at all `_ensure_srs_present` compiles a valid *empty* `.srs` via sing-box so the VPN still starts (degraded RU routing) instead of failing.
- `/tmp/eclipvpn/` — all runtime state. Wiped on reboot. Contains `servers.json` (chmod 600, the MERGED pool from all enabled subs, each server tagged `sub_id`/`sub_name`, has VLESS UUIDs / hysteria2 passwords), per-subscription parse caches `sub.<id>.servers.json` (fetch-then-swap PER sub so one blocked panel keeps its servers), generated `xray.json`/`singbox.json`, pid files, logs (`xray.log`, `singbox.log`), `incidents.json`, `traffic_state.json`, `last_switch.json`, `last_update.json`, `subscription_meta.json` (object keyed by `sub_id`: per-provider title/quota/expiry), `op.in_progress`, `watchdog.lockdir/`, `auto_state.json`.

`servers.json`, `xray.json`, `singbox.json`, and the subscription raw fetch are credential files (UUIDs / Reality private keys / Clash secret). Always `chmod 600` after writing.

## Non-obvious invariants

These are documented in inline comments at the relevant call sites — read them before touching that area. Listed here so you know they exist:

- **Watchdog is single-instance** via `mkdir $ECLIPVPN_TMP/watchdog.lockdir` (atomic on busybox; flock-based locking previously raced with init.d). Killing peers from inside `cmd_watchdog` is forbidden — traps may not be installed yet.
- **Watchdog drives log rotation, auto-recovery, and failover.** If you stop spawning it, logs grow unbounded and externally-killed VPN never revives.
- **Log writes use append-mode (`>>`)** for both daemons. Rotation does `cat tmp > file` (truncate-overwrite, preserves inode) — never `mv tmp file` (swaps inode; daemons keep writing to the unlinked old fd, lines never appear in UI).
- **`cmd_restart` is "soft"** — it preserves nftables + dnsmasq redirect across the process swap, so the LAN fails *closed* (no internet) instead of leaking direct traffic. Only `cmd_stop` does full teardown. It also has an **unchanged-config fast path**: if the freshly-generated xray/sing-box configs are byte-identical to what's running *and* the tunnel is live, it skips the swap and returns `{"status":"unchanged",...}` — but falls through to a real restart if the tunnel is dead. `restart 1` (force, always sent by the UI's Restart button, so the UI never actually sees "unchanged") bypasses this fast path; internal callers (set-mode / set-server / watchdog failover) leave it on.
- **`op.in_progress` sentinel** is set during user-initiated lifecycle ops. Watchdog defers revival while it's held; otherwise watchdog races `cmd_restart`'s `stop_xray` window and spawns a parallel xray fighting for port 1080.
- **`running_intent` (in config) ≠ `auto_start`.** `auto_start` is only consulted at boot; `running_intent` tells watchdog whether to revive after an external kill.
- **`pgrep -f 'eclipvpn watchdog'` matches itself.** `_ensure_watchdog` uses the `[/]usr/...` character-class trick to self-exclude — don't "simplify" it.
- **xray ≥ 26.4.17 required** — opkg ships 25.1.30 which has broken XHTTP+Reality. `install.sh` downloads the right binary by arch.
- **All JSON construction goes through jq.** Values from subscriptions (parse.sh), domain lists (singbox.sh), and HTTP requests (cgi-bin) are user/upstream-controlled. String-concatenated JSON broke or got injected at least once per file in history.
- **CGI input validation at the boundary** in `www/cgi-bin/eclipvpn` uses `case` patterns, not regex. Every parameter forwarded as a CLI arg is validated; POST bodies for `set-config` and `restore` are passed via stdin (avoids argv injection).
- **CGI has an anti-CSRF / anti-rebinding gate** (top of `www/cgi-bin/eclipvpn`, before the dispatch `case`). Two checks: (1) a `Host` allow-list — only IP literals / loopback / bare-hostname / `*.lan` pass; a dotted name with letters (a real public domain) is rejected, which kills DNS-rebinding; (2) every **state-changing** action requires a same-host `Origin` *or* `Referer` — a cross-site `fetch` sends a foreign Origin, a cross-site `<img>`/`<form>` a foreign (or, under `no-referrer`, absent) Referer, all rejected. This rides on Origin/Referer specifically because **uhttpd only forwards a fixed header allow-list to CGI** (`Accept/Host/Origin/Referer/User-Agent`) and *drops custom headers* — an `X-Requested-With`-style marker never reaches the script, so don't add a gate that depends on one. The exempt read-only set is the `status|ping|real-ping|healthcheck|diagnose|system-info|backup|traffic-poll|get-*` arm of that `case`; a **new mutating action must NOT match it**, or it ships unprotected. The UI relies on the browser sending a same-origin `Referer` automatically — don't add a `no-referrer` meta/policy to `index.html` or every write self-blocks. Without this gate, a drive-by page on the LAN could repoint `subscription_url` via one GET → full traffic MITM.
- **`save_config` is the *only* writer of config.json.** It validates JSON with `jq '.'` before `mv`-ing. Bypassing it has lost subscriptions to corrupt writes.
- **Boolean keys in config are stored as JSON `true`/`false`**, not strings. `auto_start` defaults via the explicit `if . == false then false else true end` pattern in `cmd_status` — `// true` is wrong here because jq's `//` treats `false` as falsy.
- **DNS-direct goes to Yandex 77.88.8.8 (UDP), not Cloudflare 1.1.1.1.** Cloudflare returns SERVFAIL for VTB and a few other RU bank domains — their authoritative NS refuse foreign resolvers. Yandex resolves everything and returns nearby RU CDN endpoints. Don't "modernize" this back to Cloudflare. Under CGNAT that hijacks UDP/53 (e.g. SevenSky), direct resolution can break — RU sites then go via VPN.
- **QUIC (UDP 443) reject sits *before* the force-VPN match** in the nft chain. Intentional: QUIC over Reality+XHTTP is unstable, so we want Gemini / ChatGPT etc. to fall back to TCP rather than tunnel QUIC. If you reorder force-VPN above the QUIC reject, AI services will try QUIC through the VPN and break.
- **WAN MTU is capped to 1400 on start** (`_apply_wan_mtu` in network.sh, restored on stop via `/tmp/eclipvpn/wan_mtu.orig`). Some wired CGNAT uplinks silently drop >1400-byte DF packets *and* the ICMP frag-needed replies (PMTU black hole) — the VPN handshake works but the tunnel stalls. Route-level MTU, nft MSS clamping, and xray `tcpMaxSeg` were all tried and do **not** fix it; only the interface cap does. Tunable via config `wan_mtu` (0 = leave the interface alone).
- **Watchdog throughput guard**: latency probes only prove the server *answers* — a peak-overloaded exit pings fast while shaped to a crawl. Every `TPUT_EVERY` ticks the watchdog measures real tunnel speed through SOCKS; after `TPUT_SLOW_MAX` consecutive readings under `tput_min_kbps` (default 500) it acts in two stages: (1) **re-dial** — the policer pins flows per-TCP-connection, so it first measures a fresh flow to the *same* server via throwaway xray and, if clearly fast, does `cmd_restart 1` in place (one attempt per incident); (2) **switch** — benchmarks all servers by *measured throughput* and switches only if the best candidate clears the threshold and is >2× faster. The cooldown is adaptive: it gates only while the last switch/benchmark has produced no good reading since (`tput_switch_helped=0`, the "every server is throttled" peak) — a switch that restored speed and later got re-squeezed (rolling TSPU waves, observed 2026-06-10) may act again as soon as the low reads re-accumulate (~7 min). After a *flopped* action (squeezed before any good reading) the first re-action is allowed after `TPUT_COOLDOWN_FAST` (5 min), the second waits the full `TPUT_COOLDOWN` (20 min) — a flop with a free server available was observed 2026-06-12, don't "simplify" any of this back to an unconditional cooldown. Config keys: `tput_guard` (default true), `tput_min_kbps`.
- **Boot gates in init.d**: waits up to 60s for WAN (slow CGNAT) and up to 20s for NTP clock sync before starting. Reality handshakes fail with a wrong clock, so don't remove the date check.
- **`set-config` keys are whitelisted** in `cmd_set_config` (`usr/bin/eclipvpn`), with per-key value validation. Adding a new tunable means adding it to both the key whitelist and the matching validation branch.
- **Cron markers are anchored.** Schedule lines end in `#eclipvpn`, auto-update in `#eclipvpn-update`, watchdog supervision in `#eclipvpn-watch`; `_remove_cron` greps `#eclipvpn$` (anchored) — an unanchored match once deleted the auto-update line on every schedule change. `_ensure_cron_state` (called from cmd_start and cmd_restore) reconciles crontab with config — that's what re-arms schedule/auto-update after `restore` or migration; don't add ad-hoc crontab writes elsewhere.
- **The watchdog is itself supervised** by a `*/5` cron line (`ensure-watchdog`, marker `#eclipvpn-watch`, installed unconditionally by `_ensure_cron_state`). The command self-gates on `running_intent`, so after `cmd_stop`/init.d stop a dead watchdog stays dead. Without this, an OOM-killed watchdog silently lost failover and log rotation until the next manual start.
- **Subscription and rule updates are fetch-then-swap.** `update_subscription` commits servers.json only when ≥1 server parsed (a 0-server parse once wiped the live list); `refresh_rules` (singbox.sh) fetches into `rules.new` and swaps only after a sanity check, carrying forward optional lists the new fetch missed. Don't reintroduce `rm -rf rules` before a fetch.
- **Watchdog failover re-arms**: the switch scan fires at `max_fails` and then every 15 ticks while the outage persists (`(fail_count - max_fails) % 15`). `_watchdog_pick_best` does 2 spawn-and-probe attempts per candidate (cold XHTTP+Reality flakes ~50% on first request) and uses probe ports 1182+ — disjoint from `cmd_probe_server`'s 1082+ range, which is deliberate.
- **Clash API on `:9090` is LAN-exposed.** Token is created lazily, persisted to `/etc/eclipvpn/clash_secret`, and handed to the UI through `/status`. Threat model is "trust the home LAN" — anyone on the same Wi-Fi can read traffic stats / switch proxies. Don't deploy this to a public Wi-Fi router without rethinking that.

## Adding a new command

1. Add `cmd_foo()` in the matching domain lib under `usr/lib/eclipvpn/` (lifecycle/servers/domains/traffic/health/config/watchdog) — or in `usr/bin/eclipvpn` itself only if it's core/shared infra. If you create a NEW lib file, add it to the `. "$ECLIPVPN_LIB/*.sh"` block in `usr/bin/eclipvpn` **and** to the ship lists in all three installers (`deploy.sh` — both the tar list AND the `ash -n` syntax loop — `install.sh`, and `install-from-mac.sh`). The Windows installer stages `usr/` wholesale, so it needs no edit.
2. Wire the dispatch case at the bottom of `usr/bin/eclipvpn` (`foo) cmd_foo "$2" ;;`).
3. Wire `www/cgi-bin/eclipvpn` to forward the action (and validate any new parameters in the boundary block).
4. Add fetch + render in `www/eclipvpn/index.html` (`API='/cgi-bin/eclipvpn'`, polled actions in `loadStatus`/`loadDomains`/etc).
5. Run `./deploy.sh` to ship.

## Windows installer (`windows-installer/`)

A self-contained, **fully offline** Windows `.exe` that installs EclipVPN onto a router over SSH — for end users who can't run `install.sh` on the router (GitHub is blocked in RU; dropbear has no sftp). This is the one part of the repo with a real build step. See `windows-installer/README.md` for the full picture; the load-bearing facts:

- **Layered design**: `eclip-core.ps1` (install engine over SSH.NET, mirrors `install-from-mac.sh`) ← `install-eclipvpn-gui.ps1` (WPF GUI: dark card, EN/RU, router auto-detect, colored log) / `install-eclipvpn.ps1` (headless CLI) ← `launcher.cs` (C# self-extract stub carrying `bundle.zip`, compiled by `build-exe.ps1` with the framework `csc.exe`, **not** ps2exe).
- **What's committed vs. generated**: sources (`.ps1`, `.cs`, `lang.ru.txt`, `README.md`) are tracked. The `.exe`, `bundle.zip`, `eclip.ico`, `payload/bin/<arch>/*` static binaries (xray/sing-box/jq/curl/ca, currently **aarch64 only**), and `lib/Renci.SshNet.dll` are gitignored — regenerate per the README before a build.
- **`build-exe.ps1` stages the router source straight from the working tree** (`usr/`/`www/`/`etc/`), so a rebuild always ships current code — rebuild after any change under those dirs.
- **Gotchas that bite**: keep every `.ps1` **pure ASCII** (PS 5.1 reads a BOM-less script as the ANSI codepage; localized text lives in `lang.ru.txt`, read as UTF-8 data). dropbear aborts an SSH exec >~10-16 KB, so files are pushed in ~7.5 KB base64 chunks. The C# stub detects zip dir entries by empty `entry.Name` (.NET writes `\` separators, so `EndsWith("/")` fails). `ECLIP_GUI_SMOKE=1` builds the window and auto-closes for a headless check.

## Other

- `docs/ROADMAP.md` is a wish-list of features inspired by competitor tools (ZeroBlock, Passwall, OpenClash, etc.). Not a binding plan; consult before suggesting big new directions.
- `docs/eclipvpn_manual.pdf` is the user-facing manual (RU). Source: `docs/eclipvpn_manual.tex`, build with `tectonic`.
- `docs/throttling-root-cause-2026-06-11.md` is the field write-up behind the "CDN fronting & subscription formats" section — the per-flow-policer diagnosis (raw-TLS vs VLESS, per-TCP lottery, CDN-prefix cleanness). Read it before touching the watchdog throughput guard or the throttling story.
- The `/eclipvpn/` rebrand keeps a meta-refresh redirect at `/eclipvpn/index.html` — don't break it.
- README.md (root) is the single source of truth for user-facing docs and has additional operational notes (datacenter-IP blocks at OpenAI/Anthropic, NTP requirement for Reality handshake, troubleshooting flow). Worth a skim when a question is operational rather than architectural.
