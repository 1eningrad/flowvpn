# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Brand vs. internals

User-facing brand is **EclipVPN**. As of release **2026.06** the internals were renamed `flowvpn` → `eclipvpn` as well: CLI `/usr/bin/eclipvpn`, libs `/usr/lib/eclipvpn/`, config `/etc/eclipvpn/`, runtime tmp `/tmp/eclipvpn/`, service `/etc/init.d/eclipvpn`, CGI `/www/cgi-bin/eclipvpn`, nft tables `eclipvpn`/`eclipvpn_dns`, logger tag `eclipvpn`, shell vars `$ECLIPVPN_*`, and the version constant `ECLIPVPN_VERSION` in `usr/bin/eclipvpn`.

Two things deliberately **stay `flowvpn`** — do not rename them:
- The **GitHub repo** `1eningrad/flowvpn` (the `install.sh` raw-URL and the UI footer links point at it; renaming the URL 404s the installer). Rename the repo on GitHub first if you want these to change.
- The **legacy `/www/flowvpn/` → `/eclipvpn/` redirect** stub (created by the installers) for old bookmarks.

`install.sh` / `install-from-mac.sh` / `deploy.sh` carry a one-time, idempotent **migration**: on a router with an old `flowvpn` install they stop+disable the old service, kill its watchdog (matched by the start-anchored cmdline `"/bin/ash /usr/bin/flowvpn watchdog"*`), clean its nft tables + dnsmasq drop-in, `mv /etc/flowvpn /etc/eclipvpn` (preserving subscription/settings), and remove the old files.

## What this is

A VPN manager for OpenWrt routers. Written almost entirely in **busybox ash** (`#!/bin/ash`, not bash) with a single-file HTML/JS web UI. Two binaries do the actual work: **xray** (SOCKS outbound, VLESS+XHTTP+Reality) and **sing-box** (tproxy inbound, DNS, routing). Everything else is glue.

There is no build step, no test suite, no package manager, no CI. Code is shipped to a live router via `deploy.sh`.

## Common commands

| Command | What it does |
| --- | --- |
| `./deploy.sh` | Push current tree to `root@192.168.1.1`. tar-pipes the scripts/CGI/UI, syntax-checks with `ash -n`, force-cleans stale watchdog/rules state, restarts via init.d, prints verification. |
| `ROUTER=root@10.0.0.1 ./deploy.sh` | Same, against a different router. |
| `./install.sh` | One-shot installer (run *on the router*) — installs deps, fetches xray 26.4.17 binary, writes files to canonical paths. |
| `ash -n <file>` | Syntax-check a script before deploy. `deploy.sh` already runs this on every shell file. |
| `cd docs && tectonic eclipvpn_manual.tex` | Rebuild the user manual PDF. |

There are no unit/integration tests — the `test-results/` dir is for old screenshots, not a runner. Verify changes by running `./deploy.sh` and exercising the UI.

For UI changes, hard-reload in the browser (`Cmd+Shift+R`) — the CGI sends no-cache headers but the static `index.html` is cached aggressively.

## CLI surface (existing commands)

Top-level user commands already implemented in `usr/bin/eclipvpn` — check here before adding a new one:

```
start | stop | restart [force] | status  lifecycle (restart 1 = force past unchanged-config no-op)
set-server N                             pick server by index
probe-server N                           probe a server (throwaway xray, VLESS-Reality) without touching live tunnel
set-mode all_vpn|blocklist               routing mode
update                                   refresh subscription + RU/blocklist domain rules
ping | real-ping                         TCP probe (with ICMP fallback) / VLESS-Reality probe
diagnose | healthcheck                   quick metrics / full check (DNS, leaks, processes)
add-domain DOM vpn|direct                user override list
get-log N FILTER                         tail logs (filter: all|vpn|direct|error|dns|flow)
get-incidents | clear-incidents          failover history
reset-traffic                            zero per-chain byte counters
backup                                   export config as JSON
watchdog                                 internal — single-instance, do not call directly
```

CGI surface is the same set, dispatched via query string in `www/cgi-bin/eclipvpn`.

## Code layout

```
usr/bin/eclipvpn              CLI dispatcher, ~2200 lines, top-level cmd_* functions
usr/lib/eclipvpn/parse.sh     Subscription fetch + vless:// URL parser
usr/lib/eclipvpn/xray.sh      xray config gen + start/stop/test
usr/lib/eclipvpn/singbox.sh   sing-box config gen, RU domain list, blocklist sources
usr/lib/eclipvpn/network.sh   nftables + dnsmasq redirect setup/teardown
www/cgi-bin/eclipvpn          CGI shim: query-string → CLI dispatch
www/eclipvpn/index.html       Single-file SPA UI (installs to /www/eclipvpn/index.html)
etc/init.d/eclipvpn           OpenWrt service stub (autostart-on-boot)
deploy.sh / install.sh       Rollout scripts
```

Library scripts are sourced into `usr/bin/eclipvpn` — they share global vars (`$ECLIPVPN_TMP`, `$ECLIPVPN_CONFIG`, `$SR_RULES_DIR`, etc.) and helpers (`flog`, `get_config_val`).

## Runtime data flow

```
LAN client → dnsmasq:53 → sing-box DNS:5354 → DoH 1.1.1.1:443 (via VPN) or UDP 1.1.1.1 (direct)
LAN client → nftables tproxy:2154 → sing-box → xray SOCKS:1080 → VLESS+Reality (VPN)
                                              ↘ direct (RU geosite/geoip + custom direct list)
```

- **mark 0x1** = packet entered tproxy, route via local table 100
- **mark 0x8000** = sing-box/xray's own outbound — anti-loop bypass at the top of `eclipvpn` nft chain
- **DoT (853)** and **QUIC (UDP 443)** are unconditionally rejected so apps fall back to plain DNS / TCP that we control

## Two routing modes

- `all_vpn` — everything → VPN, *except* domains/IPs in `geosite-ru`, `geoip-ru`, and the manual RU list in `singbox.sh::_fetch_ru_domains()` (Yandex/VK/Sber/etc).
- `blocklist` — only blocked domains → VPN; everything else direct. Source is `itdoginfo/allow-domains` (curated, ~1.2k) or `1andrevich/Re-filter-lists` (~80k) when `blocklist_source=full`.

A **force-VPN list** (`vpn_domains.list`, built-in AI services + user's `custom_vpn`) overrides the RU rules in `all_vpn` mode — gemini.google.com etc. would otherwise hit `geosite-ru` (which contains `google.com`).

## Files and persistence

- `/etc/eclipvpn/config.json` (chmod 600) — sole config file. Subscription URL, mode, `auto_start`, `auto_mode`, `running_intent`, `device_rules`, `schedule`, `selected_server`. Always write atomically via `save_config` (validates with `jq '.'` then `mv`).
- `/etc/eclipvpn/clash_secret` (chmod 600) — 32-hex Clash API token, lazily created by `_get_clash_secret`. UI fetches it via `/status`.
- `/etc/eclipvpn/{direct,vpn}_domains.txt` — user's custom domain lists (one per line).
- `/tmp/eclipvpn/` — all runtime state. Wiped on reboot. Contains `servers.json` (chmod 600, has VLESS UUIDs), generated `xray.json`/`singbox.json`, pid files, logs (`xray.log`, `singbox.log`), `incidents.json`, `traffic_state.json`, `last_switch.json`, `last_update.json`, `subscription_meta.json`, `op.in_progress`, `watchdog.lockdir/`, `auto_state.json`.

`servers.json`, `xray.json`, `singbox.json`, and the subscription raw fetch are credential files (UUIDs / Reality private keys / Clash secret). Always `chmod 600` after writing.

## Non-obvious invariants

These are documented in inline comments at the relevant call sites — read them before touching that area. Listed here so you know they exist:

- **Watchdog is single-instance** via `mkdir $ECLIPVPN_TMP/watchdog.lockdir` (atomic on busybox; flock-based locking previously raced with init.d). Killing peers from inside `cmd_watchdog` is forbidden — traps may not be installed yet.
- **Watchdog drives log rotation, auto-recovery, and failover.** If you stop spawning it, logs grow unbounded and externally-killed VPN never revives.
- **Log writes use append-mode (`>>`)** for both daemons. Rotation does `cat tmp > file` (truncate-overwrite, preserves inode) — never `mv tmp file` (swaps inode; daemons keep writing to the unlinked old fd, lines never appear in UI).
- **`cmd_restart` is "soft"** — it preserves nftables + dnsmasq redirect across the process swap, so the LAN fails *closed* (no internet) instead of leaking direct traffic. Only `cmd_stop` does full teardown. It also has an **unchanged-config fast path**: if the freshly-generated xray/sing-box configs are byte-identical to what's running *and* the tunnel is live, it skips the swap and returns `{"status":"unchanged",...}` (UI shows "VPN уже работает") — but falls through to a real restart if the tunnel is dead. `restart 1` (force, sent by the UI's manual Restart button) bypasses this fast path; internal callers (set-mode / set-server / watchdog failover) leave it on.
- **`op.in_progress` sentinel** is set during user-initiated lifecycle ops. Watchdog defers revival while it's held; otherwise watchdog races `cmd_restart`'s `stop_xray` window and spawns a parallel xray fighting for port 1080.
- **`running_intent` (in config) ≠ `auto_start`.** `auto_start` is only consulted at boot; `running_intent` tells watchdog whether to revive after an external kill.
- **`pgrep -f 'eclipvpn watchdog'` matches itself.** `_ensure_watchdog` uses the `[/]usr/...` character-class trick to self-exclude — don't "simplify" it.
- **xray ≥ 26.4.17 required** — opkg ships 25.1.30 which has broken XHTTP+Reality. `install.sh` downloads the right binary by arch.
- **All JSON construction goes through jq.** Values from subscriptions (parse.sh), domain lists (singbox.sh), and HTTP requests (cgi-bin) are user/upstream-controlled. String-concatenated JSON broke or got injected at least once per file in history.
- **CGI input validation at the boundary** in `www/cgi-bin/eclipvpn` uses `case` patterns, not regex. Every parameter forwarded as a CLI arg is validated; POST bodies for `set-config` and `restore` are passed via stdin (avoids argv injection).
- **`save_config` is the *only* writer of config.json.** It validates JSON with `jq '.'` before `mv`-ing. Bypassing it has lost subscriptions to corrupt writes.
- **Boolean keys in config are stored as JSON `true`/`false`**, not strings. `auto_start` defaults via the explicit `if . == false then false else true end` pattern in `cmd_status` — `// true` is wrong here because jq's `//` treats `false` as falsy.
- **DNS-direct goes to Yandex 77.88.8.8 (UDP), not Cloudflare 1.1.1.1.** Cloudflare returns SERVFAIL for VTB and a few other RU bank domains — their authoritative NS refuse foreign resolvers. Yandex resolves everything and returns nearby RU CDN endpoints. Don't "modernize" this back to Cloudflare. Under CGNAT that hijacks UDP/53 (e.g. SevenSky), direct resolution can break — RU sites then go via VPN.
- **QUIC (UDP 443) reject sits *before* the force-VPN match** in the nft chain. Intentional: QUIC over Reality+XHTTP is unstable, so we want Gemini / ChatGPT etc. to fall back to TCP rather than tunnel QUIC. If you reorder force-VPN above the QUIC reject, AI services will try QUIC through the VPN and break.
- **Clash API on `:9090` is LAN-exposed.** Token is created lazily, persisted to `/etc/eclipvpn/clash_secret`, and handed to the UI through `/status`. Threat model is "trust the home LAN" — anyone on the same Wi-Fi can read traffic stats / switch proxies. Don't deploy this to a public Wi-Fi router without rethinking that.

## Adding a new command

1. Add `cmd_foo()` in `usr/bin/eclipvpn` (or extend a library file if it fits there).
2. Wire the dispatch case at the bottom of `usr/bin/eclipvpn` (`foo) cmd_foo "$2" ;;`).
3. Wire `www/cgi-bin/eclipvpn` to forward the action (and validate any new parameters in the boundary block).
4. Add fetch + render in `www/eclipvpn/index.html` (`API='/cgi-bin/eclipvpn'`, polled actions in `loadStatus`/`loadDomains`/etc).
5. Run `./deploy.sh` to ship.

## Other

- `docs/ROADMAP.md` is a wish-list of features inspired by competitor tools (ZeroBlock, Passwall, OpenClash, etc.). Not a binding plan; consult before suggesting big new directions.
- `docs/eclipvpn_manual.pdf` is the user-facing manual (RU). Source: `docs/eclipvpn_manual.tex`, build with `tectonic`.
- The `/eclipvpn/` rebrand keeps a meta-refresh redirect at `/eclipvpn/index.html` — don't break it.
- README.md (root) is the single source of truth for user-facing docs and has additional operational notes (datacenter-IP blocks at OpenAI/Anthropic, NTP requirement for Reality handshake, troubleshooting flow). Worth a skim when a question is operational rather than architectural.
