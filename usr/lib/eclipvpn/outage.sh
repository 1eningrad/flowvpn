#!/bin/ash
# EclipVPN — outages in the journal: ONE record per outage, closed in place.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers.
#
# A record is {ts, type:"outage", host, server, detail, diag} and gets
# {end, closed, to} when it is over (closed = recovered|switched|stopped).
# $ECLIPVPN_TMP/outage ("ts last_fail host name…") marks the one that is open
# right now: it survives a watchdog restart, and a reboot wipes it — which is
# why an unclosed record WITHOUT the marker reads as "unknown", never as
# "recovered": nobody saw how it ended. wan_down uses wan_down_since the same way.

# Another process is mid start/stop/restart: what we see is its doing.
_outage_op_busy() {
    local p
    [ -f "$ECLIPVPN_TMP/op.in_progress" ] || return 1
    p=$(cat "$ECLIPVPN_TMP/op.in_progress" 2>/dev/null)
    [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null
}

# Rewrite the journal with jq filter $1 (extra args go to jq).
_incidents_edit() {
    local filter="$1" f="$ECLIPVPN_TMP/incidents.json" tmp="$ECLIPVPN_TMP/incidents.json.tmp.$$.o"
    shift
    mkdir -p "$ECLIPVPN_TMP"
    [ -s "$f" ] || echo '[]' > "$f"
    (
        command -v flock >/dev/null 2>&1 && flock -x 9
        jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$f" || rm -f "$tmp"
    ) 9> "$ECLIPVPN_TMP/incidents.lock"
    _mirror_state incidents.json
}

# What tells the exit, the path and the proxy apart, taken once when the outage
# is declared. $1 = its start epoch. Nothing private: destinations in xray's
# errors (the sites people open) are blanked, access lines are never read.
_outage_diag() {
    local since="$1" port cfg addr sport t rc tcp="не проверялся" errs="" utc
    port=$(_active_socks_port)
    cfg="$ECLIPVPN_TMP/xray.$port.json"
    if is_xray_running && [ -s "$cfg" ]; then
        # The IP xray itself dials: resolving the name now would go through the
        # dead tunnel and blame the server for it.
        addr=$(jq -r '[.outbounds[0].settings | .. | objects | .address? // empty][0] // empty' "$cfg" 2>/dev/null)
        sport=$(jq -r '[.outbounds[0].settings | .. | objects | .port? // empty][0] // empty' "$cfg" 2>/dev/null)
        if [ -n "$addr" ] && [ -n "$sport" ]; then
            t=$(curl -sk -o /dev/null --connect-timeout 4 --max-time 4 -w '%{time_connect}' "https://$addr:$sport/" 2>/dev/null)
            rc=$?
            case "$t" in
                ''|0|0.000000|0,000000) [ "$rc" = 7 ] && tcp="не открылся" || tcp="нет ответа за 4 с" ;;
                *) tcp="отвечает, $(echo "$t" | awk '{printf "%d", $1 * 1000}') мс" ;;
            esac
        fi
        utc=$(date -u -d "@$since" '+%Y/%m/%d %H:%M:%S' 2>/dev/null)
        [ -n "$utc" ] && [ -f "$ECLIPVPN_TMP/xray.log" ] && \
            errs=$(tail -n 400 "$ECLIPVPN_TMP/xray.log" | _outage_xray_errors "$utc")
    fi
    jq -nc --arg tcp "$tcp" --arg probes "${WD_PROBE_ALL:-}" --arg xray "$errs" \
        '{tcp:$tcp, probes:$probes, xray:($xray | split("\n") | map(select(length>0)))}'
}

# stdin: xray log; $1 = "YYYY/MM/DD HH:MM:SS" (UTC). At most 3 distinct error
# causes. Only the tail of xray's " > " chain is kept, and anything that looks
# like an address, a domain or an id is blanked.
_outage_xray_errors() {
    awk -v s="$1" '($1 " " substr($2,1,8)) >= s && (/\[Warning\]/ || /\[Error\]/) && !/ accepted /' \
        | sed -e 's/.* > //' -e 's/^[0-9/]* [0-9:.]* //' \
              -e 's/\[[0-9a-fA-F:]*\]\(:[0-9][0-9]*\)*/…/g' \
              -e 's/[A-Za-z0-9_-]*\(\.[A-Za-z0-9_-][A-Za-z0-9_-]*\)\{1,\}\(:[0-9][0-9]*\)*/…/g' \
              -e 's/[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F:]*/…/g' \
              -e 's/[0-9a-fA-F]\{8\}-[0-9a-fA-F-]*/…/g' \
        | cut -c1-140 | sort -u | head -n 3
}

# $1 = start epoch, $2 = why. No-op while one is open (just its heartbeat).
_outage_open() {
    local ts="$1" why="$2" idx host name
    if [ -f "$ECLIPVPN_TMP/outage" ]; then _outage_beat; return 0; fi
    _outage_op_busy && return 0
    idx=$(get_config_val selected_server 0)
    host=$(jq -r ".[$idx].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    name=$(jq -r ".[$idx].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    local diag; diag=$(_outage_diag "$ts")
    [ -n "$diag" ] || diag='{}'
    _incidents_edit '. + [{ts:$ts, type:"outage", host:$host, server:$name, detail:$why, diag:$diag}] | .[-200:]' \
        --argjson ts "$ts" --arg host "$host" --arg name "$name" --arg why "$why" --argjson diag "$diag"
    echo "$ts $(date +%s) ${host:--} $name" > "$ECLIPVPN_TMP/outage"
}

_outage_beat() {
    local ts last host name
    read -r ts last host name < "$ECLIPVPN_TMP/outage" || return 0
    echo "$ts $(date +%s) $host $name" > "$ECLIPVPN_TMP/outage"
}

# $1 = recovered|switched|stopped, $2 = the new server's name (switched).
# A heartbeat older than 15 min means nobody watched: leave the end unknown.
_outage_close() {
    local ts last host name now
    [ -f "$ECLIPVPN_TMP/outage" ] || return 0
    read -r ts last host name < "$ECLIPVPN_TMP/outage"
    rm -f "$ECLIPVPN_TMP/outage"
    now=$(date +%s)
    case "$ts$last" in ''|*[!0-9]*) return 0 ;; esac
    [ $((now - last)) -gt 900 ] && return 0
    _incidents_edit 'map(if .type=="outage" and .ts==$ts and .end==null then . + {end:$now, closed:$c, to:$to} else . end)' \
        --argjson ts "$ts" --argjson now "$now" --arg c "$1" --arg to "${2:-}"
}

# Same for the provider's outage. $1 = recovered|stopped.
_wan_close() {
    local since
    [ -f "$ECLIPVPN_TMP/wan_down_since" ] || return 0
    since=$(cat "$ECLIPVPN_TMP/wan_down_since" 2>/dev/null)
    rm -f "$ECLIPVPN_TMP/wan_down_since" "$ECLIPVPN_TMP/wan_down_ticks"
    case "$since" in ''|*[!0-9]*) return 0 ;; esac
    _incidents_edit 'map(if .type=="wan_down" and .ts >= ($s - 5) and .end==null then . + {end:$now, closed:$c} else . end)' \
        --argjson s "$since" --argjson now "$(date +%s)" --arg c "$1"
}

# A (re)start just VERIFIED the tunnel on server index $1.
_outage_on_up() {
    local ts last host name h n
    _wan_close recovered
    [ -f "$ECLIPVPN_TMP/outage" ] || return 0
    read -r ts last host name < "$ECLIPVPN_TMP/outage"
    h=$(jq -r ".[$1].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    n=$(jq -r ".[$1].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    if [ "${h:--}" = "$host" ] && [ "$n" = "$name" ]; then _outage_close recovered
    else _outage_close switched "$n"; fi
}

_outage_on_stop() { _outage_close stopped; _wan_close stopped; }

# stdin: raw journal (any order) → folded, oldest first, `state` on every outage:
# ongoing | recovered | switched | stopped | unknown. Journals written before
# v2026.11.4 are folded too: check_fail runs become one outage whose end nobody
# recorded, wan_down + wan_recovered become one wan_down.
_incidents_fold() {
    local open=0 wan=false ts last host name
    if [ "$(get_config_val running_intent false)" = "true" ]; then
        if [ -f "$ECLIPVPN_TMP/outage" ] && read -r ts last host name < "$ECLIPVPN_TMP/outage"; then
            case "$ts$last" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - last )) -le 900 ] && open="$ts" ;; esac
        fi
        [ -f "$ECLIPVPN_TMP/wan_down_since" ] && wan=true
    fi
    jq -c --argjson open "$open" --argjson wan "$wan" --arg noalt "все кандидаты недоступны" '
      def lastidx(f): . as $a | ([range(0; length) | select($a[.] | f)] | last);
      reduce sort_by(.ts)[] as $i ([];
        if $i.type == "check_fail" then
          (lastidx(.legacy == true and .host == $i.host and ($i.ts - .last) < 600)) as $k |
          if $k != null and $k == length - 1 then .[$k].last = $i.ts
          else . + [$i + {type:"outage", legacy:true, last:$i.ts}] end
        elif $i.type == "wan_recovered" then
          (lastidx(.type == "wan_down")) as $k |
          if $k != null and .[$k].end == null then .[$k] += {end:$i.ts, closed:"recovered"}
          else . + [$i] end
        elif $i.type == "auto_switch" then
          (lastidx(.type == "outage" and .closed == "switched" and .ts <= $i.ts and $i.ts <= .end)) as $k |
          if $k != null then .[$k] += {auto:true, note:$i.detail} else . + [$i] end
        elif $i.type == "switch_failed" and $i.detail == $noalt then
          (lastidx(.type == "outage" and (.legacy | not) and .ts <= $i.ts
                   and (if .end != null then $i.ts <= .end else .ts == $open end))) as $k |
          if $k != null then .[$k].noalt = ((.[$k].noalt // 0) + 1) else . + [$i] end
        else . + [$i] end)
      | (lastidx(.type == "wan_down")) as $w
      | to_entries | map(.key as $k | .value
          | if .type == "outage" then
              .state = (if .end != null then (.closed // "unknown") elif (.legacy | not) and .ts == $open then "ongoing" else "unknown" end)
            elif .type == "wan_down" then
              .state = (if .end != null then (.closed // "unknown") elif $wan and $k == $w then "ongoing" else "unknown" end)
            else . end)'
}
