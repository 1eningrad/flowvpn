#!/bin/ash
# EclipVPN — self-update from GitHub releases (UI button «Обновить»).
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers (flog, _err,
# get_config_val, _router_fetch, _build_id). Defines functions only.
#
# Flow (cmd_self_update → detached _self_update_run):
#   check   GitHub API releases/latest → tag; newer than ECLIPVPN_VERSION?
#   fetch   codeload tarball of that tag via _router_fetch (direct, then via
#           the tunnel — raw GitHub hosts are often blocked direct from RU)
#   verify  the tree's own packaging/ship-files manifest: every listed file
#           present, non-empty, `ash -n` clean; UI present; version readable
#   backup  every file about to be replaced → /etc/eclipvpn/update_prev/
#           (persistent: a bad update that also wedges the box can still be
#           rolled back by hand after a reboot)
#   install atomic per file (.new + mv) — the running CLI keeps its old inode
#   restart the same sequence deploy.sh uses (stop, kill watchdog, wipe stale
#           locks, init.d restart) — only if the VPN was meant to be running
#   health  tunnel answers through SOCKS within 90s, else ROLL BACK + restart
#
# Progress lives in $ECLIPVPN_TMP/update_state.json so the UI can poll it:
# uhttpd kills a CGI after 60s, and the update (download + restart + health
# wait) can take longer, so the work runs detached (setsid) from the request.
#
# Test seams: ECLIPVPN_ROOT (install root, default "/") and
# ECLIPVPN_UPDATE_REPO (owner/name). Production sets neither.

_update_repo() { echo "${ECLIPVPN_UPDATE_REPO:-1eningrad/flowvpn}"; }
_update_root() { echo "${ECLIPVPN_ROOT:-}"; }
_update_prev_dir() { echo "$(dirname "$ECLIPVPN_CONFIG")/update_prev"; }

# Strip a leading "v": v2026.06.1 -> 2026.06.1
_ver_norm() { echo "${1#v}"; }

# _ver_gt A B — true if version A is strictly newer than B. Dot-separated
# numeric fields, missing fields count as 0 (2026.06 == 2026.06.0). Leading
# zeros are harmless ($((10#…)) is not portable to ash, so strip them by hand).
# A non-numeric field makes the comparison false (never "upgrade" to garbage).
_ver_gt() {
    local a b x y
    a="$(_ver_norm "$1")."; b="$(_ver_norm "$2")."
    while [ -n "$a" ] || [ -n "$b" ]; do
        x="${a%%.*}"; y="${b%%.*}"
        a="${a#*.}"; b="${b#*.}"
        [ -z "$x" ] && x=0; [ -z "$y" ] && y=0
        case "$x$y" in *[!0-9]*) return 1 ;; esac
        while [ "${#x}" -gt 1 ] && [ "${x#0}" != "$x" ]; do x="${x#0}"; done
        while [ "${#y}" -gt 1 ] && [ "${y#0}" != "$y" ]; do y="${y#0}"; done
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

# Syntax-check with the router's shell; `sh -n` where there is no ash (tests).
_update_sh_check() {
    if command -v ash >/dev/null 2>&1; then ash -n "$1" 2>/dev/null; else sh -n "$1" 2>/dev/null; fi
}

# Write the progress file atomically. $1 phase, $2 target tag, $3 message.
_update_state() {
    local f="$ECLIPVPN_TMP/update_state.json"
    mkdir -p "$ECLIPVPN_TMP"
    jq -n --arg p "$1" --arg t "${2:-}" --arg m "${3:-}" --argjson ts "$(date +%s)" \
        '{phase:$p, target:$t, message:$m, ts:$ts}' > "$f.tmp" && mv "$f.tmp" "$f"
}

# Files an update installs, repo-relative: the ship manifest + the UI.
# $1 = an unpacked release tree.
_update_files() {
    grep -v '^#' "$1/packaging/ship-files" 2>/dev/null | grep -v '^ *$'
    echo "www/eclipvpn/index.html"
}

# Version constant of an unpacked tree (from its usr/bin/eclipvpn).
_update_tree_version() {
    sed -n 's/^ECLIPVPN_VERSION="\([^"]*\)".*/\1/p' "$1/usr/bin/eclipvpn" 2>/dev/null | head -n1
}

# _update_validate DIR — the tree is complete and every shell file parses.
# Echoes the reason on failure.
_update_validate() {
    local dir="$1" f
    [ -s "$dir/packaging/ship-files" ] || { echo "в архиве нет packaging/ship-files"; return 1; }
    [ -s "$dir/www/eclipvpn/index.html" ] || { echo "в архиве нет интерфейса"; return 1; }
    [ -n "$(_update_tree_version "$dir")" ] || { echo "не удалось прочитать версию"; return 1; }
    for f in $(_update_files "$dir"); do
        case "$f" in /*|*..*) echo "недопустимый путь в манифесте: $f"; return 1 ;; esac
        [ -s "$dir/$f" ] || { echo "нет файла $f"; return 1; }
        case "$f" in www/eclipvpn/index.html) continue ;; esac
        _update_sh_check "$dir/$f" || { echo "синтаксическая ошибка в $f"; return 1; }
    done
    return 0
}

# _update_backup DIR — save every file the update will touch into the prev
# dir; files that don't exist yet are listed in .new_files so a rollback
# deletes them instead of leaving new-version leftovers behind.
_update_backup() {
    local dir="$1" root bk f
    root=$(_update_root); bk=$(_update_prev_dir)
    rm -rf "$bk"; mkdir -p "$bk" || return 1
    : > "$bk/.new_files"
    for f in $(_update_files "$dir"); do
        if [ -f "$root/$f" ]; then
            mkdir -p "$bk/$(dirname "$f")" && cp -p "$root/$f" "$bk/$f" || return 1
        else
            echo "$f" >> "$bk/.new_files"
        fi
    done
    [ -f "$root/etc/eclipvpn/build" ] && cp -p "$root/etc/eclipvpn/build" "$bk/.build"
    _build_id > "$bk/.from"
    return 0
}

# Install one file atomically with the right mode.
_update_put() {
    local src="$1" dst="$2" mode=644
    case "$dst" in */usr/bin/*|*/etc/init.d/*|*/www/cgi-bin/*) mode=755 ;; esac
    mkdir -p "$(dirname "$dst")" || return 1
    cp "$src" "$dst.new" && chmod "$mode" "$dst.new" && mv -f "$dst.new" "$dst"
}

# _update_install DIR — copy the release tree onto the install root.
_update_install() {
    local dir="$1" root f
    root=$(_update_root)
    for f in $(_update_files "$dir"); do
        _update_put "$dir/$f" "$root/$f" || return 1
    done
}

# _update_rollback — put back what _update_backup saved.
_update_rollback() {
    local root bk f
    root=$(_update_root); bk=$(_update_prev_dir)
    [ -d "$bk" ] || return 1
    ( cd "$bk" && find . -type f ! -name '.new_files' ! -name '.build' ! -name '.from' ) | sed 's#^\./##' |
    while IFS= read -r f; do
        _update_put "$bk/$f" "$root/$f"
    done
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$root/$f"
    done < "$bk/.new_files"
    [ -f "$bk/.build" ] && cp -p "$bk/.build" "$root/etc/eclipvpn/build"
    return 0
}

# Restart onto the freshly installed code — the same sequence deploy.sh runs,
# because the running watchdog holds the OLD code in memory and stale locks
# from old code must not wedge new lock primitives. Runs the NEW binaries.
_update_restart() {
    /etc/init.d/eclipvpn stop >/dev/null 2>&1
    _update_drop_old
    /etc/init.d/eclipvpn restart >/dev/null 2>&1
}

# Kill any watchdog still running OLD code and wipe lock artifacts it may
# have left. Never starts anything — safe when the VPN is meant to be off.
_update_drop_old() {
    local p
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        case $(tr '\0' ' ' < "$p/cmdline") in
            "/bin/ash /usr/bin/eclipvpn watchdog"*) kill -9 "${p##*/}" 2>/dev/null ;;
        esac
    done
    rm -rf "$ECLIPVPN_TMP/rules" \
           "$ECLIPVPN_TMP/watchdog.lock" "$ECLIPVPN_TMP/watchdog.pid" "$ECLIPVPN_TMP/watchdog.lockdir" \
           "$ECLIPVPN_TMP/op.lock" "$ECLIPVPN_TMP/op.lockdir" "$ECLIPVPN_TMP/op.in_progress" \
           "$ECLIPVPN_TMP/op.reclaim.lockdir" "$ECLIPVPN_TMP/config.lock" "$ECLIPVPN_TMP/config.reclaim.lockdir"
}

# Is the freshly restarted tunnel carrying traffic? Uses the NEW binary and
# the port file only — the updater's own in-memory functions are the OLD ones.
# Waits up to $1 seconds (default 90: a cold sing-box bind alone can take 20s).
_update_healthy() {
    local limit="${1:-90}" start now port
    start=$(date +%s)
    while :; do
        if /usr/bin/eclipvpn status 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then
            port=$(cat "$ECLIPVPN_TMP/xray_port" 2>/dev/null); port="${port:-1080}"
            case "$(curl -s -o /dev/null -m 8 -w '%{http_code}' --socks5-hostname "127.0.0.1:$port" \
                    https://cp.cloudflare.com/generate_204 2>/dev/null)" in 204|200) return 0 ;; esac
        fi
        now=$(date +%s)
        [ $((now - start)) -ge "$limit" ] && return 1
        sleep 3
    done
}

# Latest release as JSON {tag, published, notes, url}, or nothing.
_update_latest() {
    local f="$ECLIPVPN_TMP/update_latest.raw"
    mkdir -p "$ECLIPVPN_TMP"
    _router_fetch "https://api.github.com/repos/$(_update_repo)/releases/latest" "$f" \
        -H "Accept: application/vnd.github+json" -A "EclipVPN/$ECLIPVPN_VERSION" || { rm -f "$f"; return 1; }
    jq -c 'select(.tag_name != null) | {tag:.tag_name, published:(.published_at // ""),
            notes:((.body // "") | .[0:1500]), url:(.html_url // "")}' "$f" 2>/dev/null
    rm -f "$f"
}

# eclipvpn update-check — is there a newer release?
cmd_update_check() {
    local latest tag avail=false
    latest=$(_update_latest)
    [ -n "$latest" ] || { _err "не удалось получить список релизов с GitHub"; return 1; }
    tag=$(printf '%s' "$latest" | jq -r '.tag')
    _ver_gt "$tag" "$ECLIPVPN_VERSION" && avail=true
    printf '%s' "$latest" | jq -c --arg cur "$ECLIPVPN_VERSION" --arg b "$(_build_id)" --argjson a "$avail" \
        '{current:$cur, build:$b, latest:.tag, available:$a, published:.published, notes:.notes, url:.url}'
}

# eclipvpn update-status — the progress file (or idle).
cmd_update_status() {
    local f="$ECLIPVPN_TMP/update_state.json"
    if [ -s "$f" ]; then cat "$f"; else echo '{"phase":"idle"}'; fi
}

# eclipvpn self-update [TAG] — start an update in the background and return.
# TAG defaults to the latest release; it must be newer than what runs.
# `self-update --file PATH` installs a local release tarball (testing / offline).
cmd_self_update() {
    local arg="${1:-}" file="" tag=""
    if [ "$arg" = "--file" ]; then
        file="${2:-}"
        [ -s "$file" ] || { _err "self-update: файл не найден: $file"; return 1; }
        tag="local"
    elif [ -n "$arg" ]; then
        case "$arg" in v[0-9]*) ;; *) _err "self-update: неверный тег '$arg'"; return 1 ;; esac
        case "$arg" in *[!0-9A-Za-z._-]*) _err "self-update: неверный тег '$arg'"; return 1 ;; esac
        tag="$arg"
    else
        tag=$(_update_latest | jq -r '.tag // empty')
        [ -n "$tag" ] || { _err "не удалось получить список релизов с GitHub"; return 1; }
    fi
    if [ -z "$file" ] && ! _ver_gt "$tag" "$ECLIPVPN_VERSION"; then
        jq -n -c --arg t "$tag" --arg c "$ECLIPVPN_VERSION" '{status:"up_to_date", latest:$t, current:$c}'
        return 0
    fi
    local lock="$ECLIPVPN_TMP/update.lockdir" owner
    mkdir -p "$ECLIPVPN_TMP"
    if ! mkdir "$lock" 2>/dev/null; then
        owner=$(cat "$lock/owner" 2>/dev/null)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            _err "обновление уже идёт"; return 1
        fi
        rm -rf "$lock"; mkdir "$lock" 2>/dev/null || { _err "обновление уже идёт"; return 1; }
    fi
    _update_state queued "$tag" "запуск"
    # Detach from the CGI request (uhttpd kills it at 60s). The child takes
    # over the lock by writing its own pid into it.
    if command -v setsid >/dev/null 2>&1; then
        setsid /usr/bin/eclipvpn self-update-run "$tag" "$file" </dev/null >/dev/null 2>&1 &
    else
        /usr/bin/eclipvpn self-update-run "$tag" "$file" </dev/null >/dev/null 2>&1 &
    fi
    echo "$!" > "$lock/owner"
    jq -n -c --arg t "$tag" '{status:"started", target:$t}'
}

# The detached worker. $1 tag, $2 optional local tarball.
_self_update_run() {
    local tag="${1:-}" file="${2:-}" work tgz dir err intent ver
    local lock="$ECLIPVPN_TMP/update.lockdir"
    echo "$$" > "$lock/owner" 2>/dev/null
    work="$ECLIPVPN_TMP/update.work"
    rm -rf "$work"; mkdir -p "$work"
    tgz="$work/release.tar.gz"

    if [ -n "$file" ]; then
        cp "$file" "$tgz"
    else
        _update_state downloading "$tag" "скачивание $tag с GitHub"
        flog "Self-update: downloading $tag"
        if ! _router_fetch "https://codeload.github.com/$(_update_repo)/tar.gz/refs/tags/$tag" "$tgz" -L; then
            _update_state failed "$tag" "не удалось скачать $tag"
            flog "ERROR: Self-update: download of $tag failed"
            rm -rf "$work" "$lock"; return 1
        fi
    fi

    _update_state validating "$tag" "проверка архива"
    if ! tar xzf "$tgz" -C "$work" 2>/dev/null; then
        _update_state failed "$tag" "архив повреждён"
        flog "ERROR: Self-update: $tag tarball does not unpack"
        rm -rf "$work" "$lock"; return 1
    fi
    dir=""
    for dir in "$work"/*/; do dir="${dir%/}"; break; done
    [ -d "$dir" ] || dir="$work"
    if ! err=$(_update_validate "$dir"); then
        _update_state failed "$tag" "архив не прошёл проверку: $err"
        flog "ERROR: Self-update: $tag rejected — $err"
        rm -rf "$work" "$lock"; return 1
    fi
    ver=$(_update_tree_version "$dir")

    _update_state installing "$tag" "установка $ver"
    if ! _update_backup "$dir"; then
        _update_state failed "$tag" "не удалось сохранить текущую версию — обновление отменено"
        flog "ERROR: Self-update: backup failed, nothing changed"
        rm -rf "$work" "$lock"; return 1
    fi
    if ! _update_install "$dir"; then
        _update_rollback
        _update_state failed "$tag" "ошибка записи файлов — возвращена прежняя версия"
        flog "ERROR: Self-update: install of $tag failed, rolled back"
        rm -rf "$work" "$lock"; return 1
    fi
    printf '%s %s via=self-update\n' "$tag" "$(date +%Y-%m-%d)" > "$(_update_root)/etc/eclipvpn/build"
    flog "Self-update: installed $tag ($ver)"

    intent=$(get_config_val running_intent false)
    if [ "$intent" = "true" ]; then
        _update_state restarting "$tag" "перезапуск VPN"
        _update_restart
        _update_state checking "$tag" "проверка связи"
        if ! _update_healthy 90; then
            flog "ERROR: Self-update: tunnel did not come up on $tag — rolling back"
            _update_state rolling_back "$tag" "VPN не поднялся — возврат прежней версии"
            _update_rollback
            _update_restart
            _update_state rolled_back "$tag" "VPN не поднялся на $tag — возвращена прежняя версия"
            _log_incident "update_rollback" "" "" "обновление до $tag откатено: VPN не поднялся"
            rm -rf "$work" "$lock"; return 1
        fi
    else
        # VPN deliberately off: do NOT restart (init.d restart would switch it
        # on). Just make sure no watchdog keeps running the old code.
        _update_drop_old
    fi
    _update_state done "$tag" "обновлено до $tag"
    _log_incident "update" "" "" "обновлено до $tag"
    flog "Self-update: done — now on $tag"
    rm -rf "$work" "$lock"
    return 0
}
