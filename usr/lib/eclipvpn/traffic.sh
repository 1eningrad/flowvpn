#!/bin/ash
# EclipVPN — traffic accounting via Clash API: live poll + cumulative per-chain.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

# Polled traffic snapshot — proxies the Clash API /traffic stream into a
# single JSON line for the UI. Replaces the previous direct-WebSocket-from-
# browser model: clash_api is now bound to 127.0.0.1, so the secret never
# leaves the router and LAN devices can't drive sing-box's clash interface.
cmd_traffic_poll() {
    local secret
    secret=$(_get_clash_secret 2>/dev/null)
    [ -z "$secret" ] && { echo '{"up":0,"down":0}'; return; }
    # /traffic streams one JSON object per second. --max-time caps the
    # request at ~1.3s so the CGI returns promptly even if the stream stalls.
    local line
    line=$(curl -s --max-time 1.3 -H "Authorization: Bearer $secret" \
        http://127.0.0.1:9090/traffic 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        printf '%s\n' "$line"
    else
        echo '{"up":0,"down":0}'
    fi
}
cmd_get_traffic() {
    # Honest per-outbound accounting via Clash API /connections.
    #
    # The API returns a snapshot of currently-active connections, each with
    # cumulative upload/download since that connection started, plus a
    # "chains" array showing which outbound it routed through ("default" =
    # VPN, "direct" = bypass). Closed connections drop off the list and
    # their final bytes would be lost.
    #
    # We maintain a state file with per-connection-id last-seen counters.
    # On each poll we compute deltas and add them to per-chain totals;
    # connections that have closed are simply not in the new snapshot, so
    # their last-known bytes stay accumulated. Result: cumulative VPN_dl,
    # VPN_ul, DIR_dl, DIR_ul since tracking started (cleared on sing-box
    # restart by start_singbox).
    #
    # The whole RMW is wrapped in flock — UI polls every 5s and two open
    # tabs would otherwise both read the same `seen` snapshot, compute
    # the same deltas, and double-count traffic.
    mkdir -p "$ECLIPVPN_TMP"
    local state_file="$ECLIPVPN_TMP/traffic_state.json"
    (
        command -v flock >/dev/null 2>&1 && flock -x 200
        [ -f "$state_file" ] || \
            printf '%s\n' '{"vpn_dl":0,"vpn_ul":0,"dir_dl":0,"dir_ul":0,"started":0,"seen":{}}' > "$state_file"

        local conns secret
        secret=$(_get_clash_secret)
        conns=$(curl -s --max-time 3 -H "Authorization: Bearer $secret" \
            http://127.0.0.1:9090/connections 2>/dev/null)

        if [ -z "$conns" ] || ! echo "$conns" | jq -e . >/dev/null 2>&1; then
            jq '. + {total_dl:0, total_ul:0, vpn_active:0, direct_active:0,
                     vpn_conns:0, direct_conns:0, api_ok:false} | del(.seen)' "$state_file"
            return 0
        fi

        local new_state
        new_state=$(jq -n \
        --slurpfile state "$state_file" \
        --argjson conns "$conns" '
        ($state[0]) as $s |
        ($s.seen // {}) as $seen |
        ($conns.connections // []) as $active |
        # Classify each active connection: dir if "direct" appears in chains,
        # otherwise vpn (covers "default" and any other proxy chain).
        ($active | map({
            id: .id,
            dl: (.download // 0),
            ul: (.upload // 0),
            chain: (if (.chains // [] | index("direct")) then "dir" else "vpn" end)
        })) as $cur |
        # Compute per-connection deltas. If current < previously-seen (rare:
        # the connection ID was reused after close), fall back to the full
        # current value rather than going negative.
        ($cur | map(
            . + {
                dl_delta: (if .dl >= (($seen[.id].dl) // 0) then .dl - (($seen[.id].dl) // 0) else .dl end),
                ul_delta: (if .ul >= (($seen[.id].ul) // 0) then .ul - (($seen[.id].ul) // 0) else .ul end)
            }
        )) as $deltas |
        ($deltas | map(select(.chain == "vpn"))) as $vpn |
        ($deltas | map(select(.chain == "dir"))) as $dir |
        # New seen{}: only currently-active IDs. Closed ones drop out, but
        # their bytes were already added to vpn_*/dir_* on prior polls.
        ($cur | map({key: .id, value: {dl: .dl, ul: .ul, chain: .chain}}) | from_entries) as $new_seen |
        {
            vpn_dl: ($s.vpn_dl + (($vpn | map(.dl_delta) | add) // 0)),
            vpn_ul: ($s.vpn_ul + (($vpn | map(.ul_delta) | add) // 0)),
            dir_dl: ($s.dir_dl + (($dir | map(.dl_delta) | add) // 0)),
            dir_ul: ($s.dir_ul + (($dir | map(.ul_delta) | add) // 0)),
            started: (if $s.started > 0 then $s.started else now | floor end),
            seen: $new_seen
        }
    ')

        if [ -n "$new_state" ] && echo "$new_state" | jq -e . >/dev/null 2>&1; then
            printf '%s\n' "$new_state" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        fi

        # Public response — strip the internal seen{} and add live fields.
        cat "$state_file" | jq \
            --argjson conns "$conns" \
            '{
                vpn_dl, vpn_ul, dir_dl, dir_ul, started,
                total_dl: ($conns.downloadTotal // 0),
                total_ul: ($conns.uploadTotal // 0),
                vpn_active: ([$conns.connections[]? | select(.chains | index("direct") | not)
                                                    | (.upload // 0) + (.download // 0)] | add // 0),
                direct_active: ([$conns.connections[]? | select(.chains | index("direct"))
                                                    | (.upload // 0) + (.download // 0)] | add // 0),
                vpn_conns: ([$conns.connections[]? | select(.chains | index("direct") | not)] | length),
                direct_conns: ([$conns.connections[]? | select(.chains | index("direct"))] | length),
                api_ok: true
            }'
    ) 200>"$state_file.lock"
}
cmd_real_ping() {
    # Real end-to-end latency through VLESS+Reality+XHTTP, not just TCP RTT
    # to :443. Uses sing-box's Clash-API delay endpoint, which dials the
    # actual outbound and times an HTTP HEAD to gstatic.com/generate_204.
    # Cheap (≤5s) and exact — what users actually feel.
    if ! is_singbox_running; then
        echo '{"ok":false, "error":"sing-box not running"}'
        return
    fi
    local secret=$(_get_clash_secret)
    local resp
    resp=$(curl -s --max-time 7 -H "Authorization: Bearer $secret" \
        "http://127.0.0.1:9090/proxies/default/delay?url=https://www.gstatic.com/generate_204&timeout=5000" 2>/dev/null)
    if [ -z "$resp" ]; then
        echo '{"ok":false, "error":"clash api unavailable"}'
        return
    fi
    # Either {"delay":NN} on success or {"message":"..."} on failure.
    local delay
    delay=$(echo "$resp" | jq -r '.delay // empty' 2>/dev/null)
    if [ -n "$delay" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
        echo "{\"ok\":true, \"delay_ms\":$delay}"
    else
        local msg
        msg=$(echo "$resp" | jq -r '.message // "timeout"' 2>/dev/null)
        jq -n --arg e "$msg" '{ok:false, error:$e}'
    fi
}
cmd_reset_traffic() {
    # Reset cumulative per-chain counters (vpn_dl/ul, dir_dl/ul) and start a
    # fresh accounting window. Keeps `seen{}` populated with current
    # connection IDs so the next poll computes deltas from now, not from
    # whatever bytes those open connections had accumulated before.
    local state_file="$ECLIPVPN_TMP/traffic_state.json"
    mkdir -p "$ECLIPVPN_TMP"
    (
        command -v flock >/dev/null 2>&1 && flock -x 200
        local now=$(date +%s)
        local seen='{}'
        if [ -f "$state_file" ]; then
            seen=$(jq '.seen // {}' "$state_file" 2>/dev/null || echo '{}')
        fi
        jq -n --argjson seen "$seen" --argjson ts "$now" \
            '{vpn_dl:0, vpn_ul:0, dir_dl:0, dir_ul:0, started:$ts, seen:$seen}' \
            > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    ) 200>"$state_file.lock"
    echo "{\"status\":\"reset\",\"started\":$(date +%s)}"
}
