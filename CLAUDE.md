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

There is no build step and no package manager for the router code — it is shipped to a live router as-is via `deploy.sh` (CI does exist: syntax + manifest + unit checks, see "Testing"). (The Windows installer under `windows-installer/` is the one piece with a build step — see its section below.) There **is** a unit-test suite (`tests/`, added 2026-06-16) covering the pure parsers, input validators, and the lock / config-write primitives — see "Testing" below and `docs/invariants.md`.

## Common commands

| Command | What it does |
| --- | --- |
| `./deploy.sh` | Ship to `root@192.168.1.1`. **`git pull --rebase` first, then tar-pipes `git archive HEAD` — COMMITTED bytes, not the working tree** (see the deploy-ships-HEAD invariant). Syntax-checks with `ash -n`, force-cleans stale watchdog/rules state, restarts via init.d, prints verification. |
| `ROUTER=root@10.0.0.1 ./deploy.sh` | Same, against a different router. |
| `SKIP_PULL=1 ./deploy.sh` | Skip the `git pull` (GitHub is often unreachable from inside RU). Does **not** change what ships. |
| `ALLOW_DIRTY=1 ./deploy.sh` | Ship the working tree instead of HEAD — the only way to deploy uncommitted edits. Racy vs Yandex.Disk sync; opt-in only. Also honoured by `install-from-mac.sh`. |
| `./install.sh` | One-shot installer (run *on the router*) — installs deps, fetches xray 26.4.17 binary, writes files to canonical paths. |
| `sh install-from-mac.sh` | Bootstrap a *fresh* router from the local tree over SSH (default `root@192.168.2.1`), bypassing the GitHub repo — pushes the same files as `install.sh` but from the working tree. Use for first-time provisioning / after a factory reset; `deploy.sh` is for updating an already-installed router. `WITH_REMOTE=0` skips the Tailscale step. |
| `ash -n <file>` | Syntax-check a script before deploy. `deploy.sh` already runs this on every shell file. |
| `sh tests/run.sh [suite...]` | Run the unit suite (needs `jq`). No args = all; `parse`/`validators`/`locks`/`config` = one suite. Exit non-zero on any failure. See "Testing". |
| `cd docs && tectonic eclipvpn_manual.tex` | Rebuild the user manual PDF. |
| `cd windows-installer && powershell -ExecutionPolicy Bypass -File build-exe.ps1` | Rebuild `EclipVPN-Installer.exe` (offline Windows installer). Stages the live `usr/`/`www/`/`etc/` tree — rebuild after any router-code change. See its own section below. |

### Testing

`sh tests/run.sh [suite...]` — ash+jq unit suite (~300 assertions) that sources the REAL code (`usr/bin/eclipvpn` with `ECLIPVPN_SOURCE_ONLY=1`) against a scratch `ECLIPVPN_TMP`/`ECLIPVPN_CONFIG`; suites are `tests/test_*.sh`, picked up by GLOB (never hardcode a list — one rotted). An isolation guard aborts (rc 3) if a sourced lib clobbers the scratch paths — libs must have no top-level assignments. CI (`.github/workflows/ci.yml`) runs `sh -n` + `busybox ash -n` over `packaging/ship-files`, the manifest guard, advisory shellcheck, and the suite under **busybox ash with busybox applets** (catches GNU-only flags like `flock -w`). `tests/` is dev-only, not shipped. The suite covers pure/lock logic, not the live tunnel — verify runtime behaviour with `./deploy.sh` + the UI (hard-reload, `Cmd+Shift+R`). Full details: `docs/invariants.md` § Testing.

## CLI surface (existing commands)

Top-level user commands already implemented in `usr/bin/eclipvpn` — check here before adding a new one:

```
start | stop | restart [force] | status  lifecycle (restart 1 = force past unchanged-config no-op)
set-server N                             pick server by index (index into the MERGED multi-sub pool)
probe-server N                           probe a server (throwaway engine — xray, or sing-box dialer for hysteria2) without touching live tunnel
mute-server N | unmute-server N          add/remove a server's NAME in `muted_servers` — hides it from the AUTOMATIC pickers only
sub list|add URL [NAME]|remove ID        manage multiple provider subscriptions (config.subscriptions[])
sub enable ID|disable ID|rename ID NAME  toggle / rename a subscription (ID = md5-8 of its URL)
sub filter ID TOKENS|off             per-subscription server_filter (keep only name-matching servers from THIS sub)
set-mode all_vpn|blocklist               routing mode
update                                   refresh ALL enabled subscriptions (merge) + RU/blocklist domain rules
auto-select | auto-eval                  pick fastest server by probe / re-evaluate live server health
ping | real-ping                         TCP probe (with ICMP fallback) / VLESS-Reality probe
diagnose | healthcheck                   quick metrics / full check (DNS, leaks, processes)
net-check                                classify the DIRECT uplink: full / whitelist (only Yandex answers — «белые списки») / none
system-info                              firmware + xray/sing-box versions, uptime, resources
add-domain DOM vpn|direct                add to user override list
remove-domain DOM vpn|direct             remove from user override list
get-domains                              dump custom + built-in vpn/direct lists
preset list|enable|disable NAME          bundled domain presets (defined in rules.sh)
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
usr/bin/eclipvpn              CLI dispatcher: init, the dispatch case,
                              core helpers (get_config_val/flog/save_config/_op_*/
                              _rotate_log/_ensure_watchdog) and the shared incident
                              helpers (_is_metered_server/_record_switch/_log_incident)
usr/lib/eclipvpn/parse.sh     PURE parsers: vless/vmess/trojan/ss/hysteria2 URLs
                              + base64/JSON subscription bodies → server objects
usr/lib/eclipvpn/subscriptions.sh  multi-provider fetch + merge + `sub` mgmt
                              (fetch_subscription/update_subscription/_remap/cmd_sub
                              /_migrate_subscriptions); was split out of parse.sh+config
usr/lib/eclipvpn/xray.sh      xray config gen + start/stop/test
usr/lib/eclipvpn/singbox.sh   sing-box config gen (generate_singbox_config + rule-builders),
                              proxy outbounds, probe-config gen, start/stop/is-running
usr/lib/eclipvpn/rules.sh     routing-rule + domain-list SOURCING (split out of singbox.sh
                              2026-06-16): .srs fetch/compile, RU-direct/force-VPN/blocklist
                              domain lists, service presets. Shares singbox.sh's globals.
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

- `all_vpn` — everything → VPN, *except* domains/IPs in `geosite-ru`, `geoip-ru`, and the manual RU list in `rules.sh::_fetch_ru_domains()` (Yandex/VK/Sber/etc).
- `blocklist` — only blocked domains → VPN; everything else direct. Source is `itdoginfo/allow-domains` (curated, ~1.2k) or `1andrevich/Re-filter-lists` (~80k) when `blocklist_source=full`.

**`full_tunnel` (set-config bool, default false)** — in `all_vpn` mode, drops the RU→direct rules entirely (`_build_allvpn_rules` skips the `geosite-ru`/`geoip-ru`/manual-RU → `direct` route rules AND the `geosite-ru`/RU → `dns-direct` DNS rules; `route.final`/`dns.final` are already `default`/`dns-proxy`), so **everything — incl. RU banks — rides the VPN**. This is for networks where the *direct* path can't actually reach RU services: e.g. the router sits behind an upstream that doesn't route major RU subnets (observed 2026-06-20 — Sberbank's `84.252.x` / Yandex-Cloud range was unreachable on the direct path, traceroute dying one hop past the upstream gateway, yet `rc=200` through the VPN exit). With RU-direct on, banks get stranded on the dead direct path; `full_tunnel=true` fixes them. Trade-off: all RU traffic takes the VPN exit (more latency/bandwidth) — only enable it when direct is broken. The force-VPN DNS rule's trailing comma is stripped (`${dns_rules%,}]`) so the DNS array stays valid when the RU rules are skipped. NB: under `full_tunnel` the user's `direct_domains.txt` (→ `ru_rule`) is inert (the whole RU-direct block is skipped).

A **force-VPN list** (`vpn_domains.list`, built-in AI services **+ YouTube** + user's `custom_vpn`) overrides the RU rules in `all_vpn` mode — gemini.google.com / youtube.com etc. would otherwise hit `geosite-ru` (which contains `google.com`). YouTube is in the built-in heredoc (`rules.sh::_fetch_vpn_domains`) so every fresh install routes it through the VPN by default (it's throttled on RU networks); there is also a toggleable `youtube` service preset, but the built-in entry is the always-on baseline.

The **`ru_vpn` preset** (rules.sh) is the surgical alternative to `full_tunnel`: it force-routes specific RU services (YooKassa/YooMoney + Sber/VTB/T-Bank/Alfa websites) through the VPN for uplinks where the direct path can't reach them (the MTS blackhole case), without dragging all RU traffic onto the tunnel. Caveats baked into the preset comment: bank *apps* may still geo-block the foreign exit at login (app-layer, routing can't fix it), and Gazprombank is deliberately absent (403s even via VPN).

## Subscriptions, protocols, CDN fronting (summary — full text in `docs/invariants.md`)

- **Throttling is a per-flow policer** on foreign hosting prefixes; the real mitigation is CDN-fronted `🌐 Обход` servers (`security=tls`, `sni=*.selcdn.net`). They are NOT metered but ARE billed per traffic → keep them out of automation with `muted_servers`. Background: `docs/throttling-root-cause-2026-06-11.md`.
- **`parse.sh` auto-detects the body format** (base64 / url-safe base64 / plaintext / JSON via `jq -e` first). Busybox `tr` has no `[:space:]`; jq has no Oniguruma (no `test`/`match`/`sub`) — use `startswith`/`contains`. `base64` may be a shim over openssl.
- **Protocols**: vless/vmess/trojan/ss → **xray**; hysteria2 → **sing-box native** (xray not launched). Use `_vpn_running`/`_vpn_live`/`_selected_engine`, never bare `is_xray_running`. The vless `xhttp` branch must stay byte-identical (restart fast path compares configs).
- **Multiple subscriptions** merge flat into one `servers.json`, each server tagged `sub_id`/`sub_name`; `selected_server` stays a flat index, re-pinned by identity via `_remap_selected_server`. enable/disable/remove/filter re-merge cached pools with no network. Manual single-server entries (`sub add vless://…`) are `manual:true`, never fetched. Pool shaping: `server_filter` (keep), `server_exclude` (drop), per-sub `filter` — all ignore a 0-match result.

## Files and persistence (summary — full text in `docs/invariants.md`)

- `/etc/eclipvpn/config.json` (600) — sole config; write ONLY via `update_config` → `save_config` (validates, 3 rolling backups). Recovery: `cp config.json.1 config.json && eclipvpn restart 1`.
- `/etc/eclipvpn/` also: `clash_secret`, `hwid` (not in backup), `build` (stamped by the shipper), `subcache/` and `state/` (persistent mirrors of `/tmp` pool caches and the failover journal), `{direct,vpn}_domains.txt`, `rules/` (`.srs` cache).
- `/tmp/eclipvpn/` — all runtime state, wiped on reboot: `servers.json`, per-sub caches, generated `xray.<port>.json`/`singbox.json`, logs, incidents, locks, `op.in_progress`. `servers.json`/`xray*.json`/`singbox.json` hold credentials → always `chmod 600`.

## Non-obvious invariants (index — read the full entry in `docs/invariants.md` before touching the area)

**Process & lifecycle**
- `cmd_watchdog` is a thin loop over per-tick guards (`_wd_dns_guard`, `_wd_revive`, `_wd_net_check_guard`, `_wd_on_probe_ok`, `_wd_tput_guard`, `_wd_on_probe_fail`) that share its state through ash's dynamic scoping — never `local` a state variable inside a guard. Scenario-tested in `tests/test_watchdog.sh` with stubbed probes.
- Watchdog is single-instance (`mkdir` lockdir); never kill peers from `cmd_watchdog`. It drives log rotation, revival and failover, and is itself revived by a `*/5` cron (`ensure-watchdog`, gated on `running_intent`).
- `cmd_restart` is soft (keeps nft + dnsmasq ⇒ LAN fails closed), has an unchanged-config fast path (`restart 1` forces), and switches servers make-before-break: active xray port rotates 1080↔1081 (`xray_port`, `xray.<port>.json`); always use `_active_socks_port`.
- `op.in_progress` makes the watchdog defer; `running_intent` ≠ `auto_start` (boot only).
- `_vpn_running` keys off the selected server's engine; right after changing `selected_server` use `_vpn_live`.
- Boot gates in init.d: wait for WAN (wall-clock bound) and NTP (Reality needs a correct clock).
- `pgrep -f` self-match: keep the `[/]usr/...` trick in `_ensure_watchdog`.

**Busybox / shell traps**
- No `timeout`, no sub-second `sleep`, `flock` has only `-sxun` (no `-w`), `tr` has no `[:space:]`. Busy-poll `netstat` with wall-clock deadlines; don't "simplify".
- Only single-digit fds in redirections (dash in CI).
- Logs are appended (`>>`) and rotated by truncate-overwrite, never `mv` (inode).
- Repo forces LF (`.gitattributes`); CRLF breaks ash.

**Automatic server switching**
- `auto_failover` (default true) gates EVERY automatic `selected_server` change (failover incl. emergency pass, throughput switch, net-check guard); bail before benchmarking when off.
- `muted_servers` hides servers from automation only (name tokens, never indices); metered ≠ muted. Emergency pass lifts the mute only for connectivity, never for speed (not in the throughput guard).
- Emergency pass ranks by latency ⇒ from RU the nearest is often a RU exit; name matching can't tell RU exits from RU entries.
- `blocked_exit_countries` (default `RU`) vetoes auto-picked candidates by MEASURED exit country (CF trace `loc=`); unknown ⇒ not blocked; never applied to the user's own current/previous/manual server.
- Net-check guard switches to/from `WL` servers on a whitelist uplink, verifying candidates with real requests; prev server stored by identity, cleared on deliberate re-picks.
- Throughput guard: re-dial same server first, then switch only if >2× faster; adaptive cooldown — don't make it unconditional.
- Failover re-arms every 15 ticks; 2 probe attempts per candidate; probe ports 1182+ (watchdog) vs 1082+ (`cmd_probe_server`); scan aborts when the WAN itself is down.
- "Already on the best server" needs confirmed liveness; filter changes that drop the current server restart it.

**Networking & DNS**
- xray dials the exit by IP (`_resolve_server_ip`, deterministic lowest A record); nft anti-loop reuses it. Don't revert to domain dialing.
- `_router_fetch` is THE fetch primitive (direct, then via tunnel) — never raw `curl` for downloads.
- DNS-direct = Yandex 77.88.8.8 (Cloudflare SERVFAILs RU banks); `dns_direct_servers` is a fallback list the watchdog promotes from (no auto-failback); `dns_overrides` pins domains to a resolver, emitted byte-stable.
- QUIC/DoT reject sits before force-VPN in nft — keep that order.
- WAN MTU capped to 1400 on start (PMTU black hole); IPv6 killed on br-lan (fail closed).
- A `vpn` device rule needs a sing-box regen, not just nft.
- `_sync_zapret_exclude` keeps zapret off the VPN server IPs — call it from any path that rewrites `servers.json`.

**Config, CGI, security**
- All JSON via jq; `save_config` is the only config writer; booleans are JSON bools. Never use jq `//` for a default on a boolean — it falls back on `false`. `get_config_val` defaults only on absent/null (it used `//` until 2026-11-22, so `auto_failover`/`tput_guard`/`net_check_switch` = false were silently ignored).
- `set-config` keys are whitelisted with per-key validation; a new behaviour key must also be exposed in `/status`.
- CGI validates every param with `case`; anti-CSRF/rebinding gate (Host allow-list + same-host Origin/Referer); new mutating actions must not match the read-only arm; no `no-referrer` in the UI.
- Clash API :9090 is LAN-exposed (trusted-LAN threat model).
- Cron markers are anchored (`#eclipvpn$`); only `_ensure_cron_state` edits crontab.
- Subscription and rule updates are fetch-then-swap; never wipe before fetching.

**Shipping**
- `deploy.sh` ships COMMITTED bytes (`git archive HEAD`); commit first (`ALLOW_DIRTY=1` is the racy escape hatch).
- xray ≥ 26.4.17 required; installers self-heal curl/libcurl skew by actually running `curl --version`.
- Logging: `_err` for every user-visible error, `flogd` for debug (`log_debug`).

## Adding a new command

1. Add `cmd_foo()` in the matching domain lib under `usr/lib/eclipvpn/` (lifecycle/servers/domains/traffic/health/config/watchdog) — or in `usr/bin/eclipvpn` itself only if it's core/shared infra. If you create a NEW lib file, add it to the `. "$ECLIPVPN_LIB/*.sh"` block in `usr/bin/eclipvpn` **and** add ONE line to `packaging/ship-files` — the single ship manifest read by `deploy.sh`, `install.sh`, `install-from-mac.sh`, and `windows-installer/eclip-core.ps1`. No installer's file list needs editing anymore (they all read the manifest). The CI `manifest-guard` job fails the build if a `usr/lib/eclipvpn/*.sh` is missing from the manifest. `packaging/ship-files` is dev-only — it is NOT shipped to the router (like `tests/`).
2. Wire the dispatch case at the bottom of `usr/bin/eclipvpn` (`foo) cmd_foo "$2" ;;`).
3. Wire `www/cgi-bin/eclipvpn` to forward the action (and validate any new parameters in the boundary block).
4. Add fetch + render in `www/eclipvpn/index.html` (`API='/cgi-bin/eclipvpn'`, polled actions in `loadStatus`/`loadDomains`/etc).
5. Run `./deploy.sh` to ship.

## Windows installer (`windows-installer/`)

A self-contained, **fully offline** Windows `.exe` that installs EclipVPN onto a router over SSH — for end users who can't run `install.sh` on the router (GitHub is blocked in RU; dropbear has no sftp). This is the one part of the repo with a real build step. See `windows-installer/README.md` for the full picture; the load-bearing facts:

- **Layered design**: `eclip-core.ps1` (install engine over SSH.NET, mirrors `install-from-mac.sh`) ← `install-eclipvpn-gui.ps1` (WPF GUI: dark card, EN/RU, router auto-detect, colored log) / `install-eclipvpn.ps1` (headless CLI) ← `launcher.cs` (C# self-extract stub carrying `bundle.zip`, compiled by `build-exe.ps1` with the framework `csc.exe`, **not** ps2exe).
- **What's committed vs. generated**: sources (`.ps1`, `.cs`, `lang.ru.txt`, `README.md`) are tracked. The `.exe`, `bundle.zip`, `eclip.ico`, `payload/bin/<arch>/*` static binaries (xray/sing-box/jq/curl/ca, currently **aarch64 only**), and `lib/Renci.SshNet.dll` are gitignored — regenerate per the README before a build.
- **`build-exe.ps1` stages the router source straight from the working tree** (`usr/`/`www/`/`etc/`), so a rebuild always ships current code — rebuild after any change under those dirs.
- **Rebuilding the `.exe` is a 4-step release ritual, not one command.** The installer's SHA-256 is published in two tracked files, so after `build-exe.ps1`: (1) `Get-FileHash … -Algorithm SHA256`, (2) update the hash in `README.md` ("SHA-256:" line) **and** `docs/eclipvpn_manual.tex`, (3) rebuild the PDF (`tectonic eclipvpn_manual.tex`), (4) upload the `.exe` to the GitHub release. Skipping (2)/(3) leaves users verifying against a stale hash. Note the build must run on Windows (framework `csc.exe`), so this lands as a separate commit from router-code work done on the Mac.
- **Gotchas that bite**: keep every `.ps1` **pure ASCII** (PS 5.1 reads a BOM-less script as the ANSI codepage; localized text lives in `lang.ru.txt`, read as UTF-8 data). dropbear aborts an SSH exec >~10-16 KB, so files are pushed in ~7.5 KB base64 chunks. The C# stub detects zip dir entries by empty `entry.Name` (.NET writes `\` separators, so `EndsWith("/")` fails). `ECLIP_GUI_SMOKE=1` builds the window and auto-closes for a headless check.

## Other

- `docs/ROADMAP.md` is a wish-list of features inspired by competitor tools (ZeroBlock, Passwall, OpenClash, etc.). Not a binding plan; consult before suggesting big new directions.
- `docs/eclipvpn_manual.pdf` is the user-facing manual (RU). Source: `docs/eclipvpn_manual.tex`, build with `tectonic`.
- `docs/throttling-root-cause-2026-06-11.md` is the field write-up behind the "CDN fronting & subscription formats" section — the per-flow-policer diagnosis (raw-TLS vs VLESS, per-TCP lottery, CDN-prefix cleanness). Read it before touching the watchdog throughput guard or the throttling story.
- The `/eclipvpn/` rebrand keeps a meta-refresh redirect at `/eclipvpn/index.html` — don't break it.
- README.md (root) is the single source of truth for user-facing docs and has additional operational notes (datacenter-IP blocks at OpenAI/Anthropic, NTP requirement for Reality handshake, troubleshooting flow). Worth a skim when a question is operational rather than architectural.
