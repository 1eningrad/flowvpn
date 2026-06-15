#!/bin/ash
# EclipVPN — routing mode, custom domain lists, service presets.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

# ============================================================
# Mode & domain management
# ============================================================

cmd_set_mode() {
    local new_mode="$1"
    case "$new_mode" in
        all_vpn|blocklist) ;;
        *) echo '{"error":"invalid mode, use all_vpn or blocklist"}'; return 1 ;;
    esac
    flog "Switching mode to $new_mode"
    local tmp=$(jq --arg m "$new_mode" '.mode = $m' "$ECLIPVPN_CONFIG")
    save_config "$tmp" || { echo '{"error":"save failed"}'; return 1; }
    rm -f "$ECLIPVPN_TMP/singbox.json"
    # Rebuild rule lists for the new mode (fetch-then-swap). cmd_restart only
    # regenerates the sing-box config from existing rule files — without this
    # refresh, both modes start with empty lists (RU heredoc / blocklist /
    # force-VPN all missing) and routing collapses to the remote rule_sets.
    refresh_rules "$new_mode" || flog "WARN: rule refresh failed for mode=$new_mode — routing degraded until next update"
    if _vpn_running; then
        cmd_restart
    else
        jq -n --arg m "$new_mode" '{status:"mode set",mode:$m}'
    fi
}

cmd_add_domain() {
    local domain="$1" list="$2"
    [ -z "$domain" ] && { echo '{"error":"missing domain"}'; return 1; }
    local file
    case "$list" in
        direct) file="$CUSTOM_DIRECT" ;;
        vpn)    file="$CUSTOM_VPN" ;;
        *)      echo '{"error":"invalid list, use direct or vpn"}'; return 1 ;;
    esac
    mkdir -p /etc/eclipvpn
    # `--` so a domain starting with "-" can't be parsed as a grep option.
    grep -qxF -- "$domain" "$file" 2>/dev/null || echo "$domain" >> "$file"
    # _fetch_*_domains rebuilds the merged source list ({ru,vpn}_domains.list)
    # from heredoc + the user's custom file. cmd_restart then bakes it into
    # singbox.json's domain_suffix array — sing-box reads its config once at
    # startup, so without restarting it the new domain stays inert no matter
    # how many times we touch the merged list.
    [ "$list" = "direct" ] && _fetch_ru_domains 2>/dev/null
    [ "$list" = "vpn" ] && _fetch_vpn_domains 2>/dev/null
    local applied=false
    if _vpn_running && cmd_restart >/dev/null 2>&1; then
        applied=true
    fi
    jq -n --arg d "$domain" --arg l "$list" --argjson a "$applied" \
        '{status:"added", domain:$d, list:$l, applied:$a}'
}

cmd_remove_domain() {
    local domain="$1" list="$2"
    [ -z "$domain" ] && { echo '{"error":"missing domain"}'; return 1; }
    local file
    case "$list" in
        direct) file="$CUSTOM_DIRECT" ;;
        vpn)    file="$CUSTOM_VPN" ;;
        *)      echo '{"error":"invalid list"}'; return 1 ;;
    esac
    [ -f "$file" ] && { grep -vxF -- "$domain" "$file" > "${file}.tmp"; mv "${file}.tmp" "$file"; }
    [ "$list" = "direct" ] && _fetch_ru_domains 2>/dev/null
    [ "$list" = "vpn" ] && _fetch_vpn_domains 2>/dev/null
    local applied=false
    if _vpn_running && cmd_restart >/dev/null 2>&1; then
        applied=true
    fi
    jq -n --arg d "$domain" --arg l "$list" --argjson a "$applied" \
        '{status:"removed", domain:$d, list:$l, applied:$a}'
}

cmd_get_domains() {
    local direct_domains="[]" vpn_domains="[]" ru_builtin="[]" vpn_builtin="[]"
    # Materialize the built-in lists on demand. The RU-direct (195) and force-VPN
    # (36) lists are pure offline heredocs, but they normally only get written at
    # tunnel start (which needs a subscription + network). Without this a fresh /
    # never-started / post-reboot router (/tmp is wiped) shows 0 exceptions
    # instead of the defaults a running router shows. No internet needed here;
    # the next real start still regenerates the full set (incl. downloaded .srs).
    mkdir -p "$SR_RULES_DIR" 2>/dev/null
    [ -f "$SR_RULES_DIR/ru_domains.list" ]  || _fetch_ru_domains  2>/dev/null
    [ -f "$SR_RULES_DIR/vpn_domains.list" ] || _fetch_vpn_domains 2>/dev/null
    [ -f "$CUSTOM_DIRECT" ] && direct_domains=$(jq -R -s 'split("\n") | map(select(length > 0 and (startswith("#") | not)))' "$CUSTOM_DIRECT")
    [ -f "$CUSTOM_VPN" ] && vpn_domains=$(jq -R -s 'split("\n") | map(select(length > 0 and (startswith("#") | not)))' "$CUSTOM_VPN")

    # Built-in lists = entries in {ru,vpn}_domains.list minus the user's
    # custom additions (those are appended last by _fetch_*_domains).
    local ru_count=0 blocked_count=0
    if [ -f "$SR_RULES_DIR/ru_domains.list" ]; then
        ru_count=$(grep -c "^DOMAIN" "$SR_RULES_DIR/ru_domains.list" 2>/dev/null)
        ru_builtin=$(awk -F, '/^DOMAIN-SUFFIX,/ {print $2}' "$SR_RULES_DIR/ru_domains.list" \
            | jq -R -s --argjson custom "$direct_domains" \
                'split("\n") | map(select(length > 0)) | . - $custom')
    fi
    if [ -f "$SR_RULES_DIR/vpn_domains.list" ]; then
        vpn_builtin=$(grep -vE '^(#|$)' "$SR_RULES_DIR/vpn_domains.list" \
            | jq -R -s --argjson custom "$vpn_domains" \
                'split("\n") | map(select(length > 0)) | . - $custom')
    fi
    [ -f "$SR_RULES_DIR/domains.list" ] && blocked_count=$(grep -c "^DOMAIN" "$SR_RULES_DIR/domains.list" 2>/dev/null)

    jq -n --argjson direct "$direct_domains" --argjson vpn "$vpn_domains" \
        --argjson ru_builtin "$ru_builtin" --argjson vpn_builtin "$vpn_builtin" \
        --argjson ru_count "$ru_count" --argjson blocked_count "$blocked_count" \
        '{custom_direct:$direct, custom_vpn:$vpn,
          ru_domains_builtin:$ru_builtin, vpn_domains_builtin:$vpn_builtin,
          ru_domains_count:$ru_count, blocked_domains_count:$blocked_count}'
}

# ============================================================
# Service presets — one-click toggles for popular services that
# would otherwise require the user to hand-type domain lists.
# Underlying domains live in singbox.sh::_preset_domains; this
# layer just maintains config.enabled_presets and rebuilds the
# vpn_domains.list + bounces sing-box.
# ============================================================

cmd_preset() {
    local op="${1:-list}" name="$2"

    # _preset_names and _preset_domains live in singbox.sh which is sourced
    # at startup, so they're already in scope here.
    _preset_known() {
        local n
        for n in $(_preset_names); do
            [ "$n" = "$1" ] && return 0
        done
        return 1
    }

    case "$op" in
        list)
            # Echo {presets: [{name, enabled, domain_count}]}. Domain count
            # comes from running _preset_domains and counting non-comment
            # non-empty lines, so it auto-tracks edits to the inline lists.
            local enabled_json
            enabled_json=$(jq -c '.enabled_presets // []' "$ECLIPVPN_CONFIG" 2>/dev/null)
            [ -z "$enabled_json" ] && enabled_json='[]'
            local arr='[]'
            for n in $(_preset_names); do
                local cnt
                cnt=$(_preset_domains "$n" | grep -cvE '^(#|$)')
                arr=$(echo "$arr" | jq --arg n "$n" --argjson c "$cnt" --argjson e "$enabled_json" \
                    '. + [{name:$n, enabled:($e | index($n) != null), domain_count:$c}]')
            done
            echo "$arr" | jq '{presets: .}'
            ;;
        enable|disable)
            [ -z "$name" ] && { echo '{"error":"name required"}'; return 1; }
            if ! _preset_known "$name"; then
                echo "{\"error\":\"unknown preset: $name\"}"
                return 1
            fi
            local tmp
            if [ "$op" = "enable" ]; then
                tmp=$(jq --arg n "$name" \
                    '.enabled_presets = (((.enabled_presets // []) + [$n]) | unique)' \
                    "$ECLIPVPN_CONFIG")
            else
                tmp=$(jq --arg n "$name" \
                    '.enabled_presets = ((.enabled_presets // []) - [$n])' \
                    "$ECLIPVPN_CONFIG")
            fi
            save_config "$tmp" || { echo '{"error":"save failed"}'; return 1; }

            # Rebuild vpn_domains.list and apply via cmd_restart — same flow
            # as add-domain. A bare start_singbox here was a double bug: it
            # spawned a SECOND sing-box over the live one (ports taken → the
            # newcomer died after 10s, clobbering the pidfile on the way out)
            # and never regenerated singbox.json, so the preset's domains
            # stayed inert until some unrelated restart.
            _fetch_vpn_domains 2>/dev/null
            local applied=false
            if _vpn_running && cmd_restart >/dev/null 2>&1; then
                applied=true
            fi
            jq -n --arg s "$op" --arg p "$name" --argjson a "$applied" \
                '{status:$s, preset:$p, applied:$a}'
            ;;
        *)
            echo "{\"error\":\"unknown op: $op (use list/enable/disable)\"}"
            return 1
            ;;
    esac
}
