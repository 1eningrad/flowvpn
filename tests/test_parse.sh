# test_parse.sh — pure parsers in parse.sh. Sourced by run.sh (asserts + env).

# --- url_decode (the #5 fix: literal backslash survives, %XX decodes) ---
_t url_decode
assert_eq "backslash+%2F" "$(url_decode 'a\b%2Fc')" 'a\b/c'
assert_eq "plus-to-space"  "$(url_decode 'x+y')"     'x y'
assert_eq "leading-dash"   "$(url_decode '-nfoo')"   '-nfoo'

# --- _b64_pad (busybox tr gotcha: a 'c' in the data must survive) ---
_t b64_pad
# "abc" -> len 3 -> one '=' ; the 'c' must NOT be eaten.
assert_eq "pads-len3"      "$(_b64_pad 'abc')"  'abc='
assert_eq "keeps-c"        "$(_b64_pad 'abcd')" 'abcd'
assert_eq "strips-ws"      "$(_b64_pad 'ab cd')" 'abcd'

# --- vless ---
_t vless
V=$(parse_proxy_url 'vless://uuid-1234@1.2.3.4:443?security=reality&pbk=KEY&sni=x.com&type=xhttp#My Server')
assert_rc  "vless-ok-rc" "$?" 0
assert_json "vless-proto"  "$V" '.protocol' vless
assert_json "vless-host"   "$V" '.host' 1.2.3.4
assert_json "vless-port"   "$V" '.port|tostring' 443
assert_json "vless-uuid"   "$V" '.uuid' uuid-1234
assert_json "vless-sec"    "$V" '.security' reality
assert_json "vless-name"   "$V" '.name' 'My Server'
# nameless entry must NOT leak the uuid into .name
VN=$(parse_proxy_url 'vless://leak-uuid@9.9.9.9:443?security=tls')
assert_json "vless-noleak" "$VN" '.name' ''
# placeholder host / bad port rejected
parse_proxy_url 'vless://u@0.0.0.0:443'   >/dev/null 2>&1; assert_rc "vless-rej-placeholder" "$?" 1
parse_proxy_url 'vless://u@1.2.3.4:0'     >/dev/null 2>&1; assert_rc "vless-rej-port0"       "$?" 1
parse_proxy_url 'vless://u@1.2.3.4:99999' >/dev/null 2>&1; assert_rc "vless-rej-portbig"     "$?" 1
parse_proxy_url 'vless://@1.2.3.4:443'    >/dev/null 2>&1; assert_rc "vless-rej-nouuid"      "$?" 1
# extra: malformed JSON falls back to {} ; valid object kept
VBAD=$(parse_proxy_url 'vless://u@1.2.3.4:443?extra=notjson')
assert_json "vless-extra-bad" "$VBAD" '.extra' '{}'
VOK=$(parse_proxy_url 'vless://u@1.2.3.4:443?extra=%7B%22x%22%3A1%7D')
assert_json "vless-extra-ok" "$VOK" '(.extra|fromjson).x|tostring' 1

# --- trojan ---
_t trojan
T=$(parse_proxy_url 'trojan://pa ss@h.example:443?sni=x.com#T')
assert_json "trojan-proto" "$T" '.protocol' trojan
assert_json "trojan-pass"  "$T" '.password' 'pa ss'
assert_json "trojan-sec-default-tls" "$T" '.security' tls

# --- shadowsocks (SIP002, base64 userinfo) ---
_t shadowsocks
SSB=$(printf '%s' 'aes-256-gcm:secret' | base64 | tr -d '\n')
S=$(parse_proxy_url "ss://${SSB}@1.2.3.4:8388#SS")
assert_json "ss-proto"  "$S" '.protocol' shadowsocks
assert_json "ss-method" "$S" '.method' aes-256-gcm
assert_json "ss-pass"   "$S" '.password' secret
assert_json "ss-host"   "$S" '.host' 1.2.3.4
# plugin= is out of scope -> rejected
parse_proxy_url "ss://${SSB}@1.2.3.4:8388?plugin=obfs#SS" >/dev/null 2>&1; assert_rc "ss-rej-plugin" "$?" 1

# --- vmess (base64 JSON) ---
_t vmess
VM=$(printf '%s' '{"add":"5.6.7.8","port":"443","id":"vmuuid","net":"ws","path":"/p","tls":"tls","ps":"VM"}' | base64 | tr -d '\n')
M=$(parse_proxy_url "vmess://${VM}")
assert_json "vmess-proto" "$M" '.protocol' vmess
assert_json "vmess-host"  "$M" '.host' 5.6.7.8
assert_json "vmess-uuid"  "$M" '.uuid' vmuuid
assert_json "vmess-net"   "$M" '.transport' ws

# --- hysteria2 ---
_t hysteria2
H=$(parse_proxy_url 'hysteria2://authpw@h.example:443/?obfs=salamander&obfs-password=op&insecure=1&sni=s.com#HY')
assert_json "hy2-proto"    "$H" '.protocol' hysteria2
assert_json "hy2-pass"     "$H" '.password' authpw
assert_json "hy2-obfs"     "$H" '.obfs' salamander
assert_json "hy2-obfspw"   "$H" '.obfs_pw' op
assert_json "hy2-insecure" "$H" '.insecure|tostring' 1
# hy2:// alias parses the same
HA=$(parse_proxy_url 'hy2://authpw@h.example:443#HY')
assert_json "hy2-alias" "$HA" '.protocol' hysteria2
# non-salamander obfs is dropped (sing-box only knows salamander)
HO=$(parse_proxy_url 'hysteria2://pw@h.example:443/?obfs=xplus&obfs-password=op#HY')
assert_json "hy2-obfs-dropped" "$HO" '.obfs' ''
# missing userinfo @ -> rejected
parse_proxy_url 'hysteria2://h.example:443' >/dev/null 2>&1; assert_rc "hy2-rej-no-at" "$?" 1

# --- unknown scheme ---
_t dispatch
parse_proxy_url 'tuic://x@1.2.3.4:443' >/dev/null 2>&1; assert_rc "unknown-rej" "$?" 1

# --- parse_subscription_file: plaintext list + JSON body ---
_t subscription_file
PT="$ECLIPVPN_TMP/sub_plain.txt"; OUT="$ECLIPVPN_TMP/sub_out.json"
printf '%s\n%s\n%s\n' 'vless://u1@1.1.1.1:443#A' 'tuic://nope@2.2.2.2:443#X' 'vless://u2@3.3.3.3:443#B' > "$PT"
cnt=$(parse_subscription_file "$PT" "$OUT")
assert_eq "subfile-plain-count" "$cnt" 2
assert_json "subfile-plain-hosts" "$(cat "$OUT")" '[.[].host]|join(",")' '1.1.1.1,3.3.3.3'

JS="$ECLIPVPN_TMP/sub_json.txt"; OUTJ="$ECLIPVPN_TMP/sub_out_j.json"
printf '%s' '[{"protocol":"vless","host":"4.4.4.4","port":443,"uuid":"jx","name":"J"},"vless://u@5.5.5.5:443#K"]' > "$JS"
cntj=$(parse_subscription_file "$JS" "$OUTJ")
assert_eq "subfile-json-count" "$cntj" 2
