#!/bin/bash
###############################################################################
# LucX-UI PRO — universal VPN/proxy panel installer
# Architecture based on mozaroc/3x-ui-pro, adapted for AlexeyLCP/lucx-ui.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/sacredx72/lucx-ui/main/install_pro.sh) \
#       -subdomain panel.example.com -reality_domain r.example.com
#
# What you get (single public :443 unless noted):
#   VLESS:  REALITY+Vision | WS | gRPC | TCP-http-obfs | XHTTP(UDS)
#   VMess:  WS | gRPC | TCP-http-obfs
#   Trojan: WS | gRPC
#   Shadowsocks: WS | gRPC | TCP-http-obfs
#   Hysteria2 (public UDP) · MTProto (public TCP) · NaiveProxy,
#   TrustTunnel, mieru, qWDTT, olcRTC (sidecar protocols, own ports)
#   Subscriptions: SUB(base64) / JSON / Clash-Mihomo(UA-autodetect) / AWG-path
#   Happ + Incy RoscomVPN routing profiles · nginx decoy · network diagnostics
# OS: Debian 12/13, Ubuntu 24.04/26.04
###############################################################################
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }
die()     { msg_err "$1"; exit 1; }

echo; msg_inf '  ╔═══════════════════════════════════════╗'
msg_inf '  ║   LucX-UI PRO — universal installer   ║'
msg_inf '  ╚═══════════════════════════════════════╝'; echo

# ─── Pre-flight ──────────────────────────────────────────────────────────────
os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
os_ver=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release 2>/dev/null)
case "${os_id}" in
    ubuntu) [[ "$os_ver" == "24.04" || "$os_ver" == "26.04" ]] || die "Unsupported Ubuntu ${os_ver}" ;;
    debian) [[ "$os_ver" == "12" || "$os_ver" == "13" ]] || die "Unsupported Debian ${os_ver}" ;;
    *) die "Unsupported OS: ${os_id}" ;;
esac

_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64) echo 'amd64' ;;
        armv8*|armv8|arm64|aarch64) echo 'arm64' ;;
        *) die "Unsupported arch $(uname -m)" ;;
    esac
}

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
LUCX_REPO="AlexeyLCP/lucx-ui"
GITHUB_RAW="https://raw.githubusercontent.com/sacredx72/lucx-ui/main"
FAKE_SITE_COUNT=50

# ─── Args ────────────────────────────────────────────────────────────────────
domain=""; reality_domain=""
UNINSTALL="x"; INSTALL="y"; AUTODOMAIN="n"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -install)        INSTALL="$2";        shift 2 ;;
        -subdomain)      domain="$2";         shift 2 ;;
        -reality_domain) reality_domain="$2"; shift 2 ;;
        -auto_domain)    AUTODOMAIN="$2";     shift 2 ;;
        -uninstall)      UNINSTALL="$2";      shift 2 ;;
        *)               shift ;;
    esac
done
Pak=$(type apt &>/dev/null && echo apt || echo yum)

# ─── Generators ──────────────────────────────────────────────────────────────
gen_str()   { head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$1"; echo; }
gen_gid()   { head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c 16; }
gen_uuid()  { cat /proc/sys/kernel/random/uuid; }
get_rport() { echo $(( ((RANDOM<<15)|RANDOM) % 20000 + 20000 )); }
port_free() { ! nc -z 127.0.0.1 "$1" &>/dev/null; }
make_port() { local p; while true; do p=$(get_rport); port_free "$p" && { echo "$p"; break; }; done; }

# ─── Fixed + random ports/paths ──────────────────────────────────────────────
REALITY_PORT=8443     # xray REALITY behind SNI (public via :443)
WWW_PORT=7443         # nginx TLS vhost behind SNI (public via :443)
DECOY_PORT=9443       # nginx decoy vhost — REALITY dest

panel_port=$(make_port); sub_port=$(make_port)
p_ws_v=$(make_port);  p_grpc_v=$(make_port);  p_tobf_v=$(make_port)
p_ws_vm=$(make_port); p_grpc_vm=$(make_port); p_tobf_vm=$(make_port)
p_ws_t=$(make_port);  p_grpc_t=$(make_port)
p_ws_s=$(make_port);  p_grpc_s=$(make_port);  p_tobf_s=$(make_port)
hys_port=$(make_port); mtproto_port=$(make_port)
naive_port=$(make_port); trust_port=$(make_port); mieru_port=$(make_port)

panel_path=$(gen_str 10); sub_path=$(gen_str 10); json_path=$(gen_str 10)
clash_path=$(gen_str 10); awg_path=$(gen_str 10)
cp_ws_v=$(gen_str 10);  cp_grpc_v=$(gen_str 10);  cp_tobf_v=$(gen_str 10)
cp_ws_vm=$(gen_str 10); cp_grpc_vm=$(gen_str 10); cp_tobf_vm=$(gen_str 10)
cp_ws_t=$(gen_str 10);  cp_grpc_t=$(gen_str 10)
cp_ws_s=$(gen_str 10);  cp_grpc_s=$(gen_str 10);  cp_tobf_s=$(gen_str 10)
mtr_backend_port=$(make_port)   # diagnostics backend (localhost-only)
config_username=$(gen_str 10); config_password=$(gen_str 10)
diag_path="/net-$(gen_str 12)/"; diag_token=$(gen_str 16)

# ─── Uninstall ───────────────────────────────────────────────────────────────
if [[ ${UNINSTALL} == *"y"* ]]; then
    printf 'y\n' | x-ui uninstall 2>/dev/null || true
    systemctl stop mtr-backend 2>/dev/null || true
    systemctl disable mtr-backend 2>/dev/null || true
    rm -rf /etc/x-ui /usr/local/x-ui /usr/bin/x-ui \
           /var/www/html /var/www/diagnostics /var/www/subpage \
           /etc/systemd/system/mtr-backend.service /usr/local/lib/lucx-pro \
           "/root/cert/${domain}"
    $Pak -y purge 'nginx*' python3-certbot-nginx >/dev/null 2>&1 || true
    rm -rf /etc/nginx
    systemctl daemon-reload 2>/dev/null || true
    clear && msg_ok "Completely uninstalled!" && exit 0
fi

# ─── Server IP / domains ─────────────────────────────────────────────────────
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s --max-time 10 ipv4.icanhazip.com | tr -d '[:space:]')

validate_domains() {
    while [[ -z "$domain" ]]; do echo -en "Panel subdomain: "; read -r domain; done
    while [[ -z "$reality_domain" ]]; do echo -en "REALITY subdomain: "; read -r reality_domain; done
    domain=$(echo "$domain" | tr -d '[:space:]')
    reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')
    if [[ "$AUTODOMAIN" == *"y"* ]]; then
        for d in "$domain" "$reality_domain"; do
            a=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
            [[ "$a" == "$IP4" ]] || die "$d -> $a, but server IP is $IP4 — fix DNS first"
        done
    fi
    [[ "$domain" != "$reality_domain" ]] || die "Domains must differ"
    msg_ok "panel: ${domain}  |  reality: ${reality_domain}"
}

clean_previous_install() {
    systemctl stop x-ui 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui
    rm -rf /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/stream-enabled/*
}

install_packages() {
    ufw disable 2>/dev/null || true
    [[ ${INSTALL} == *"y"* ]] || return 0
    export DEBIAN_FRONTEND=noninteractive
    $Pak -y update >/dev/null
    $Pak -y install curl wget jq openssl sqlite3 nginx-full certbot \
        python3-certbot-nginx ufw netcat-openbsd mtr-tiny python3 libcap2-bin >/dev/null
    systemctl daemon-reload && systemctl enable --now nginx >/dev/null 2>&1
    msg_ok "packages installed"
}

get_ssl_certs() {
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 2>/dev/null || true
    for d in "$domain" "$reality_domain"; do
        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email -d "$d" >>/var/log/lucxpro-certbot.log 2>&1
        [[ -d "/etc/letsencrypt/live/${d}" ]] || {
            systemctl start nginx >/dev/null 2>&1
            die "SSL for ${d} failed — check A-record (${d} -> ${IP4})"
        }
    done
    mkdir -p "/root/cert/${domain}"
    ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "/root/cert/${domain}/fullchain.pem"
    ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   "/root/cert/${domain}/privkey.pem"
    systemctl start nginx 2>/dev/null || true
    msg_ok "SSL certificates obtained"
}

install_panel() {
    cd /usr/local/
    tag_version=$(curl -Ls --retry 3 --max-time 30 \
        "https://api.github.com/repos/${LUCX_REPO}/releases/latest" \
        | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    [[ "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || die "Cannot resolve lucx-ui latest release"
    echo "Installing lucx-ui ${tag_version} ..."
    wget -qN -O x-ui-linux-$(_arch).tar.gz \
        "https://github.com/${LUCX_REPO}/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz" || die "Tarball download failed"
    wget -qO /usr/bin/x-ui-temp "https://raw.githubusercontent.com/${LUCX_REPO}/main/x-ui.sh" || die "x-ui.sh download failed"
    rm -rf /usr/local/x-ui
    tar zxf x-ui-linux-$(_arch).tar.gz && rm -f x-ui-linux-$(_arch).tar.gz
    cd x-ui && chmod +x x-ui x-ui.sh bin/xray-linux-$(_arch)
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui && chmod +x /usr/bin/x-ui
    ./x-ui setting -username bootstrap -password bootstrap01 \
        -port "${panel_port}" -webBasePath "/${panel_path}/" >/dev/null 2>&1
    ./x-ui migrate >/dev/null 2>&1
    cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
    systemctl daemon-reload && systemctl enable x-ui >/dev/null 2>&1
    msg_ok "lucx-ui ${tag_version} installed"
}

# ─── SQL helpers ─────────────────────────────────────────────────────────────
sql_esc() { local s="$1"; s="${s//\'/\'\'}"; printf '%s' "$s"; }
sq()      { sqlite3 "$XUIDB" "$1"; }

# JSON builders (printf — no quote-splicing anywhere)
NOW_MS=""; now_ms() { NOW_MS="$(date +%s)000"; }

jc_vless() { # $1 uuid $2 flow
    printf '{"clients":[{"id":"%s","flow":"%s","email":"%s","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","reset":0}],"decryption":"none","fallbacks":[]}' \
        "$1" "${2:-}" "$CLIENT_EMAIL" "$CLIENT_SUBID"
}
jc_trojan() { printf '{"clients":[{"password":"%s","email":"%s","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","reset":0}],"fallbacks":[]}' "$1" "$CLIENT_EMAIL" "$CLIENT_SUBID"; }
jc_ss()     { printf '{"method":"chacha20-ietf-poly1305","clients":[{"password":"%s","email":"%s","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","reset":0}]}' "$1" "$CLIENT_EMAIL" "$CLIENT_SUBID"; }
jc_hys()    { printf '{"version":2,"clients":[{"auth":"%s","email":"%s","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","reset":0}]}' "$1" "$CLIENT_EMAIL" "$CLIENT_SUBID"; }
jc_mtproto() { printf '{"fakeTlsDomain":"%s","clients":[{"secret":"%s","adTag":"","email":"%s","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","reset":0}]}' "$domain" "$1" "$CLIENT_EMAIL" "$CLIENT_SUBID"; }

js_ws()    { printf '{"network":"ws","security":"none","externalProxy":[],"wsSettings":{"acceptProxyProtocol":false,"path":"/%s/%s","headers":{}}}' "$1" "$2"; }
js_grpc()  { printf '{"network":"grpc","security":"none","externalProxy":[],"grpcSettings":{"serviceName":"/%s/%s","multiMode":false}}' "$1" "$2"; }
js_tcpobfs() { printf '{"network":"tcp","security":"none","externalProxy":[],"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"http","request":{"path":["/%s/%s"],"headers":{"Host":{"%s":["%s"]}}}}}}' "$1" "$2" "$domain" "$domain"; }

SNIFF_OFF='{"enabled":false,"destOverride":[],"metadataOnly":false,"routeOnly":false}'
SNIFF_ON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

ins_inbound() { # remark sort enable listen port protocol settings stream tag sniffing
    sq "INSERT INTO inbounds (user_id,up,down,total,remark,sub_sort_index,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
VALUES (1,0,0,0,'$(sql_esc "$1")',$2,$3,0,'$(sql_esc "$4")',$5,'$(sql_esc "$6")','$(sql_esc "$7")','$(sql_esc "$8")','$(sql_esc "$9")','${10}');"
}

configure_xui_db() {
    [[ -f $XUIDB ]] || die "x-ui.db missing — panel not installed?"
    rm -f /dev/shm/uds2023.sock
    x-ui stop 2>/dev/null || true
    now_ms

    # Wipe any previous installer's rows (idempotent re-run / upgrade path)
    sq "DELETE FROM client_traffics; DELETE FROM client_inbounds; DELETE FROM clients;"
    sq "DELETE FROM hosts; DELETE FROM inbounds;"

    # REALITY keypair
    local xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    local out priv pub
    out=$("$xray_bin" x25519 2>/dev/null) || die "xray x25519 failed"
    priv=$(echo "$out" | awk -F': ' '/PrivateKey:/{print $2}')
    pub=$(echo  "$out" | awk -F': ' '/PublicKey:/{print $2}')
    [[ -z "$pub" ]] && pub=$(echo "$out" | grep '^Password' | awk '{print $3}')
    [[ -n "$priv" && -n "$pub" ]] || die "cannot parse x25519 output"
    local s1 s2 s3 s4
    s1=$(openssl rand -hex 8); s2=$(openssl rand -hex 8)
    s3=$(openssl rand -hex 8); s4=$(openssl rand -hex 8)

    # Shared first client — one identity across ALL inbounds
    CLIENT_EMAIL="user@${domain}"
    CLIENT_SUBID=$(gen_str 16)
    CLIENT_UUID=$(gen_uuid)
    CLIENT_TROJAN=$(gen_str 20)
    CLIENT_SS_PASS=$(gen_str 20)
    CLIENT_HYS_AUTH=$(gen_str 20)
    local MT_SECRET="ee$(openssl rand -hex 16)$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')"

    # ── Panel + subscriptions settings (defaults exist after migrate → replace) ──
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('webPort','${panel_port}');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('webBasePath','/${panel_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('webCertFile','/root/cert/${domain}/fullchain.pem');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('webKeyFile','/root/cert/${domain}/privkey.pem');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subEnable','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subPort','${sub_port}');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subPath','/${sub_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subURI','https://${domain}/${sub_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subJsonEnable','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subJsonPath','/${json_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subJsonURI','https://${domain}/${json_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subJsonAutoDetect','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subJsonUserAgentRegex','(?i)(sing-box|singbox|karing|hiddify|husi)');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subClashEnable','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subClashPath','/${clash_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subClashURI','https://${domain}/${clash_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subClashAutoDetect','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subAwgEnable','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subAwgPath','/${awg_path}/');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subAwgURI','https://${domain}/${awg_path}/');"
    # Happ + Incy RoscomVPN routing (hydraponique/roscomvpn-routing, source: default profile)
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subEnableRouting','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subRoutingSource','default');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subIncyEnableRouting','true');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('timeLocation','Europe/Moscow');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subUpdates','12');"
    sq "INSERT OR REPLACE INTO settings (key,value) VALUES ('subEncrypt','true');"

    # ══════ 1. VLESS REALITY + Vision — public :443 @ reality_domain ══════
    local stream_reality
    stream_reality=$(printf '{"network":"tcp","security":"reality","externalProxy":[],"realitySettings":{"show":false,"xver":0,"dest":"127.0.0.1:%s","target":"127.0.0.1:%s","serverNames":["%s"],"privateKey":"%s","minClient":"","maxClient":"","maxTimediff":0,"shortIds":["%s","%s","%s","%s"],"settings":{"publicKey":"%s","fingerprint":"chrome","serverName":"","spiderX":"/"}},"tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}' \
        "$DECOY_PORT" "$DECOY_PORT" "$reality_domain" "$priv" "$s1" "$s2" "$s3" "$s4" "$pub")
    ins_inbound "🚀 VLESS-REALITY-Vision" 1 1 "" 8443 vless \
        "$(jc_vless "$CLIENT_UUID" "xtls-rprx-vision")" \
        "$stream_reality" "inbound-reality-vision" "$SNIFF_ON"

    # ══════ 2–13. L7 kids behind nginx :443 @ panel domain ══════
    ins_inbound "⚡ VLESS-WS"       2  1 127.0.0.1 "$p_ws_v"    vless       "$(jc_vless "$CLIENT_UUID")"         "$(js_ws "$p_ws_v" "$cp_ws_v")"        "inbound-${p_ws_v}"    "$SNIFF_OFF"
    ins_inbound "⚡ VLESS-gRPC"     3  1 127.0.0.1 "$p_grpc_v"   vless       "$(jc_vless "$CLIENT_UUID")"         "$(js_grpc "$p_grpc_v" "$cp_grpc_v")"  "inbound-${p_grpc_v}"  "$SNIFF_OFF"
    ins_inbound "⚡ VLESS-TCP-obfs" 4  1 127.0.0.1 "$p_tobf_v"   vless       "$(jc_vless "$CLIENT_UUID")"         "$(js_tcpobfs "$p_tobf_v" "$cp_tobf_v")" "inbound-${p_tobf_v}"  "$SNIFF_OFF"
    ins_inbound "🔵 VMESS-WS"       5  1 127.0.0.1 "$p_ws_vm"    vmess       "$(jc_vless "$CLIENT_UUID")"         "$(js_ws "$p_ws_vm" "$cp_ws_vm")"      "inbound-${p_ws_vm}"   "$SNIFF_OFF"
    ins_inbound "🔵 VMESS-gRPC"     6  1 127.0.0.1 "$p_grpc_vm"  vmess       "$(jc_vless "$CLIENT_UUID")"         "$(js_grpc "$p_grpc_vm" "$cp_grpc_vm")" "inbound-${p_grpc_vm}" "$SNIFF_OFF"
    ins_inbound "🔵 VMESS-TCP-obfs" 7  1 127.0.0.1 "$p_tobf_vm"  vmess       "$(jc_vless "$CLIENT_UUID")"         "$(js_tcpobfs "$p_tobf_vm" "$cp_tobf_vm")" "inbound-${p_tobf_vm}" "$SNIFF_OFF"
    ins_inbound "🔴 TROJAN-WS"      8  1 127.0.0.1 "$p_ws_t"     trojan      "$(jc_trojan "$CLIENT_TROJAN")"      "$(js_ws "$p_ws_t" "$cp_ws_t")"        "inbound-${p_ws_t}"    "$SNIFF_OFF"
    ins_inbound "🔴 TROJAN-gRPC"    9  1 127.0.0.1 "$p_grpc_t"   trojan      "$(jc_trojan "$CLIENT_TROJAN")"      "$(js_grpc "$p_grpc_t" "$cp_grpc_t")"  "inbound-${p_grpc_t}"  "$SNIFF_OFF"
    ins_inbound "🟡 SS-WS"          10 1 127.0.0.1 "$p_ws_s"     shadowsocks "$(jc_ss "$CLIENT_SS_PASS")"         "$(js_ws "$p_ws_s" "$cp_ws_s")"        "inbound-${p_ws_s}"    "$SNIFF_OFF"
    ins_inbound "🟡 SS-gRPC"        11 1 127.0.0.1 "$p_grpc_s"   shadowsocks "$(jc_ss "$CLIENT_SS_PASS")"         "$(js_grpc "$p_grpc_s" "$cp_grpc_s")"  "inbound-${p_grpc_s}"  "$SNIFF_OFF"
    ins_inbound "🟡 SS-TCP-obfs"    12 1 127.0.0.1 "$p_tobf_s"   shadowsocks "$(jc_ss "$CLIENT_SS_PASS")"         "$(js_tcpobfs "$p_tobf_s" "$cp_tobf_s")" "inbound-${p_tobf_s}" "$SNIFF_OFF"

    # ══════ 14. VLESS XHTTP — UDS socket, nginx bridges /xhttp ══════
    local stream_xhttp
    stream_xhttp=$(printf '{"network":"xhttp","security":"none","externalProxy":[],"xhttpSettings":{"path":"/xhttp","host":"%s","mode":"auto"},"sockopt":{}}' "$domain")
    ins_inbound "⚡ VLESS-XHTTP" 13 1 "/dev/shm/uds2023.sock,0666" 0 vless \
        "$(jc_vless "$CLIENT_UUID")" "$stream_xhttp" "inbound-xhttp" "$SNIFF_ON"

    # ══════ 15. Hysteria2 — public UDP, own TLS ══════
    local stream_hys
    stream_hys=$(printf '{"network":"hysteria","security":"tls","externalProxy":[],"hysteriaSettings":{"version":2,"udpIdleTimeout":60},"tlsSettings":{"serverName":"%s","alpn":["h3"],"certificates":[{"certificateFile":"/root/cert/%s/fullchain.pem","keyFile":"/root/cert/%s/privkey.pem"}]}}' \
        "$domain" "$domain" "$domain")
    ins_inbound "🔥 HYSTERIA2" 14 1 "" "$hys_port" hysteria \
        "$(jc_hys "$CLIENT_HYS_AUTH")" "$stream_hys" "inbound-hysteria2" "$SNIFF_OFF"

    # ══════ 16. MTProto (mtg sidecar) — public TCP ══════
    ins_inbound "📱 MTPROTO" 15 1 "" "$mtproto_port" mtproto \
        "$(jc_mtproto "$MT_SECRET")" "{}" "inbound-mtproto" "$SNIFF_OFF"

    # ══════ 17–21. Sidecar protocols (binary: one click in panel → Tunnels) ══════
    local s_naive s_tt s_mieru s_qw s_olc
    s_naive=$(printf '{"remark":"NaiveProxy","listen":"","domain":"%s","useAcme":false,"certFile":"/root/cert/%s/fullchain.pem","keyFile":"/root/cert/%s/privkey.pem","authUser":"","authPass":"","enableH3":false,"probeResistance":true,"logLevel":"WARN","extraArgs":"","routeThroughXray":true,"useRawConfig":false,"rawConfig":"","clients":[]}' "$domain" "$domain" "$domain")
    ins_inbound "🟢 NAIVEPROXY" 16 1 "" "$naive_port" naive \
        "$s_naive" "{}" "inbound-naive" "$SNIFF_OFF"

    s_tt=$(printf '{"hostname":"%s","listen":"0.0.0.0:%s","ipv6":true,"certFile":"/root/cert/%s/fullchain.pem","keyFile":"/root/cert/%s/privkey.pem","clientDns":"","upstreamProtocol":"http2","routeThroughXray":true,"listenPreset":"fast","clients":[]}' \
        "$domain" "$trust_port" "$domain" "$domain")
    ins_inbound "🛡 TRUSTTUNNEL" 17 1 "" "$trust_port" trusttunnel \
        "$s_tt" "{}" "inbound-trusttunnel" "$SNIFF_OFF"

    s_mieru=$(printf '{"portBindings":[{"port":%s,"protocol":"TCP"}],"mtu":1400,"loggingLevel":"INFO","routeThroughXray":true,"multiplexing":"MULTIPLEXING_LOW","handshakeMode":"HANDSHAKE_NO_WAIT","trafficPattern":{"unlockAll":true},"clients":[]}' "$mieru_port")
    ins_inbound "🟣 MIERU" 18 1 "" "$mieru_port" mieru \
        "$s_mieru" "{}" "inbound-mieru" "$SNIFF_OFF"

    s_qw='{"listenAddr":"0.0.0.0:56000","wgPort":56001,"password":"","dns":"8.8.8.8","configDir":"","listenRaw":"0.0.0.0:56003","listenDirect":"","subHost":"","vkHashes":"","clientPort":9000,"workers":16,"routeThroughXray":true}'
    ins_inbound "⚪ QWDTT" 19 1 "" 56000 qwdtt "$s_qw" "{}" "inbound-qwdtt" "$SNIFF_OFF"

    s_olc='{"provider":"jitsi","roomId":"","cryptoKey":"","transport":"datachannel","dns":"8.8.8.8:53","vp8Fps":60,"vp8Batch":64,"debug":false,"routeThroughXray":false}'
    ins_inbound "🔷 OLCRTC" 20 1 "" 0 olcrtc "$s_olc" "{}" "inbound-olcrtc" "$SNIFF_OFF"

    # ══════ HOSTS table — L7 links advertise https://domain:443 ══════
    local gid_col="" gid_val=""
    if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw group_id; then
        gid_col='"group_id",'
        gid_val="'$(gen_gid)',"
    fi
    sq "DELETE FROM hosts;"
    local host_tpl="((SELECT id FROM inbounds WHERE tag='%s'),${gid_val} 0,'%s','%s',443,'tls','%s','%s','[\"h2\",\"http/1.1\"]','',0)"
    local grpc_alpn_tpl="((SELECT id FROM inbounds WHERE tag='%s'),${gid_val} 0,'%s','%s',443,'tls','%s','%s','[\"h2\"]','',0)"
    sq "INSERT INTO hosts (inbound_id,${gid_col}sort_order,remark,address,port,security,sni,host_header,alpn,fingerprint,is_hidden) VALUES
  ((SELECT id FROM inbounds WHERE tag='inbound-reality-vision'), ${gid_val} 0,'reality','${reality_domain}',443,'same','${reality_domain}','','[]','chrome',0),
  ($(printf "${host_tpl}" "inbound-${p_ws_v}" 'vless-ws' "$domain" "$domain" "$domain")),
  ($(printf "${grpc_alpn_tpl}" "inbound-${p_grpc_v}" 'vless-grpc' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_tobf_v}" 'vless-tcp-obfs' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-xhttp" 'vless-xhttp' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_ws_vm}" 'vmess-ws' "$domain" "$domain" "$domain")),
  ($(printf "${grpc_alpn_tpl}" "inbound-${p_grpc_vm}" 'vmess-grpc' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_tobf_vm}" 'vmess-tcp-obfs' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_ws_t}" 'trojan-ws' "$domain" "$domain" "$domain")),
  ($(printf "${grpc_alpn_tpl}" "inbound-${p_grpc_t}" 'trojan-grpc' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_ws_s}" 'ss-ws' "$domain" "$domain" "$domain")),
  ($(printf "${grpc_alpn_tpl}" "inbound-${p_grpc_s}" 'ss-grpc' "$domain" "$domain" "$domain")),
  ($(printf "${host_tpl}" "inbound-${p_tobf_s}" 'ss-tcp-obfs' "$domain" "$domain" "$domain"));"

    # Hysteria2 host: same TLS cert, own UDP port
    sq "INSERT INTO hosts (inbound_id,${gid_col}sort_order,remark,address,port,security,sni,host_header,alpn,fingerprint,is_hidden)
VALUES ((SELECT id FROM inbounds WHERE tag='inbound-hysteria2'),${gid_val} 0,'hysteria2','${domain}',${hys_port},'same','${domain}','','[]','',0);"

    # ══════ Seed normalized client tables (subscriptions read THESE) ══════
    sq "INSERT OR IGNORE INTO clients (email,sub_id,uuid,password,auth,flow,security,reverse,wg_private_key,wg_public_key,wg_allowed_ips,wg_pre_shared_key,wg_keep_alive,secret,ad_tag,limit_ip,total_gb,expiry_time,enable,tg_id,group_name,comment,reset,created_at,updated_at)
VALUES ('$(sql_esc "$CLIENT_EMAIL")','$(sql_esc "$CLIENT_SUBID")','$(sql_esc "$CLIENT_UUID")','$(sql_esc "$CLIENT_TROJAN")','$(sql_esc "$CLIENT_HYS_AUTH")','','','','','','','','0','','',0,0,0,1,0,'','',0,${NOW_MS},${NOW_MS});"

    sq "INSERT INTO client_inbounds (client_id,inbound_id)
SELECT c.id,i.id FROM clients c,inbounds i
WHERE c.email='$(sql_esc "$CLIENT_EMAIL")'
AND NOT EXISTS (SELECT 1 FROM client_inbounds ci WHERE ci.client_id=c.id AND ci.inbound_id=i.id);"

    # Vision flow only on the REALITY inbound (per-link override)
    sq "UPDATE client_inbounds SET flow_override='xtls-rprx-vision'
WHERE inbound_id=(SELECT id FROM inbounds WHERE tag='inbound-reality-vision')
AND client_id=(SELECT id FROM clients WHERE email='$(sql_esc "$CLIENT_EMAIL")');"

    sq "INSERT OR IGNORE INTO client_traffics (inbound_id,enable,email,up,down,total,expiry_time,reset,last_online)
SELECT (SELECT MIN(id) FROM inbounds),1,'$(sql_esc "$CLIENT_EMAIL")',0,0,0,0,0,0;"

    # Real admin credentials (bcrypt hashed by panel CLI)
    /usr/local/x-ui/x-ui setting \
        -username "${config_username}" \
        -password "${config_password}" \
        -port "${panel_port}" \
        -webBasePath "/${panel_path}/" >/dev/null

    x-ui start
    msg_ok "database configured: $(sqlite3 "$XUIDB" 'SELECT COUNT(*) FROM inbounds;') inbounds, 1 client, $(sqlite3 "$XUIDB" 'SELECT COUNT(*) FROM hosts;') hosts"
}

configure_nginx() {
    mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets /var/www/html
    local ngx_ver http2_listen="" http2_on=""
    ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
        http2_on="http2 on;"
    else
        http2_listen=" http2"
    fi

    # ── SNI router: one public :443 ──
    cat > /etc/nginx/stream-enabled/stream.conf <<STREAMCONF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}    xray;
    ${domain}            www;
    default              www;
}
upstream xray { server 127.0.0.1:${REALITY_PORT}; }
upstream www  { server 127.0.0.1:${WWW_PORT}; }
server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
STREAMCONF
    # Debian/Ubuntu load stream via /etc/nginx/modules-enabled/*.conf already;
    # only append our own load_module when it is truly absent from ALL configs.
    if ! nginx -T 2>/dev/null | grep -q 'ngx_stream_module.so'; then
        sed -i '1i load_module /usr/lib/nginx/modules/ngx_stream_module.so;' /etc/nginx/nginx.conf
    fi
    grep -q 'stream {' /etc/nginx/nginx.conf \
        || echo 'stream { include /etc/nginx/stream-enabled/*.conf; }' >> /etc/nginx/nginx.conf

    # ── Shared snippet: subs + panel-domain L7 kids ──
    cat > /etc/nginx/snippets/includes.conf <<SUBSNIP
    # ── subscriptions ──
    location /${sub_path}/   { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    location = /${sub_path}  { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location /${json_path}/  { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location = /${json_path} { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location /${clash_path}/ { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location = /${clash_path} { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location /${awg_path}/   { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
    location = /${awg_path}  { proxy_pass https://127.0.0.1:${sub_port}; proxy_set_header Host \$host; }
SUBSNIP

    _loc_ws()   { cat >> /etc/nginx/snippets/includes.conf <<LOCWS
    # ${1}
    location /${2}/${3} {
        proxy_pass http://127.0.0.1:${2};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 300s;
    }
LOCWS
}
    _loc_grpc() { cat >> /etc/nginx/snippets/includes.conf <<LOCG
    # ${1}
    location /${2}/${3} {
        grpc_pass grpc://127.0.0.1:${2};
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
    }
LOCG
}
    _loc_tcp()  { cat >> /etc/nginx/snippets/includes.conf <<LOCT
    # ${1} (http-obfs: URI+Host must survive unchanged)
    location /${2}/${3} {
        proxy_pass http://127.0.0.1:${2};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host ${domain};
        proxy_read_timeout 1d;
        proxy_buffering off;
    }
LOCT
}

    _loc_ws   "VLESS-WS"       "$p_ws_v"    "$cp_ws_v"
    _loc_grpc "VLESS-gRPC"     "$p_grpc_v"  "$cp_grpc_v"
    _loc_tcp  "VLESS-TCP-obfs" "$p_tobf_v"  "$cp_tobf_v"
    _loc_ws   "VMESS-WS"       "$p_ws_vm"   "$cp_ws_vm"
    _loc_grpc "VMESS-gRPC"     "$p_grpc_vm" "$cp_grpc_vm"
    _loc_tcp  "VMESS-TCP-obfs" "$p_tobf_vm" "$cp_tobf_vm"
    _loc_ws   "TROJAN-WS"      "$p_ws_t"    "$cp_ws_t"
    _loc_grpc "TROJAN-gRPC"    "$p_grpc_t"  "$cp_grpc_t"
    _loc_ws   "SS-WS"          "$p_ws_s"    "$cp_ws_s"
    _loc_grpc "SS-gRPC"        "$p_grpc_s"  "$cp_grpc_s"
    _loc_tcp  "SS-TCP-obfs"    "$p_tobf_s"  "$cp_tobf_s"

    cat >> /etc/nginx/snippets/includes.conf <<XHTTPLOC
    # VLESS-XHTTP via UDS
    location /xhttp {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
    }
XHTTPLOC

    cat >> /etc/nginx/snippets/includes.conf <<'FALLBACK'
    # Generic fallback: future inbounds added via panel UI work instantly
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
        client_max_body_size 0;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        if ($content_type ~* "GRPC") { grpc_pass grpc://127.0.0.1:$fwdport; }
        if ($http_upgrade ~* "(WEBSOCKET|WS)") { proxy_pass http://127.0.0.1:$fwdport; }
        if ($request_method ~* ^(PUT|POST|GET)$) { proxy_pass http://127.0.0.1:$fwdport; }
    }
    location / { try_files $uri $uri/ =404; }
FALLBACK

    # ── Panel-domain vhost (:7443, TLS terminated, PP from SNI stream) ──
    cat > "/etc/nginx/sites-available/${domain}" <<VHOST
limit_req_zone  \$binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  \$binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone \$binary_remote_addr zone=per_ip:10m;
map \$cookie_diag_key \$diag_auth { "${diag_token}" 1; default 0; }

server {
    server_tokens off;
    server_name ${domain};
    listen 127.0.0.1:${WWW_PORT} ssl${http2_listen} proxy_protocol;
    absolute_redirect off;
    root /var/www/html;
    index index.html;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    # diagnostics SSO bridge (cookie minted after panel login)
    include /etc/nginx/snippets/diag.conf;

    include /etc/nginx/snippets/includes.conf;
}
VHOST

    # ── Diagnostics snippet (referenced above) ──
    cat > /etc/nginx/snippets/diag.conf <<DIAG
    location = /${panel_path}/diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login { return 302 /${panel_path}/; }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
        return 302 ${diag_path};
    }
    location = /__diag_auth {
        internal;
        proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
        proxy_set_header Host \$host;
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }
    location ^~ ${diag_path} {
        if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
        limit_req zone=diag_page burst=10 nodelay;
        limit_conn per_ip 5;
        alias /var/www/diagnostics/;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location ^~ ${diag_path}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        limit_req zone=diag_api burst=2 nodelay;
        proxy_pass http://127.0.0.1:${mtr_backend_port}/api/mtr;
        proxy_intercept_errors off;
    }
DIAG

    # ── Decoy vhost — REALITY dest (:9443, plain TLS, no PP) ──
    cat > "/etc/nginx/sites-available/${reality_domain}" <<DECOY
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 127.0.0.1:${DECOY_PORT} ssl${http2_listen};
    root /var/www/html;
    index index.html;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
    location / { try_files \$uri \$uri/ =404; }
}
DECOY

    cat > /etc/nginx/sites-available/80.conf <<'HTTP80'
server {
    listen 80 default_server;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}
HTTP80

    ln -sf "/etc/nginx/sites-available/${domain}" /etc/nginx/sites-enabled/
    ln -sf "/etc/nginx/sites-available/${reality_domain}" /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/80.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx config test failed"; }
    systemctl restart nginx
    msg_ok "nginx: SNI :443 → xray:${REALITY_PORT} / web:${WWW_PORT}; decoy :${DECOY_PORT}"
}

install_clash_sub() {
    mkdir -p /var/www/subpage
    if curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/clash/clash.yaml" -o /var/www/subpage/clash.yaml.tpl; then
        # DOMAIN + SUB_PATH are per-install; ${SUB_ID} stays — mtr-backend
        # substitutes it per-request (client pulls its own sub via ?provider=1)
        sed -i "s|\${DOMAIN}|${domain}|g; s|\${SUB_PATH}|${sub_path}|g" /var/www/subpage/clash.yaml.tpl
        chmod 644 /var/www/subpage/clash.yaml.tpl
        chown -R www-data:www-data /var/www/subpage 2>/dev/null || true
        msg_ok "Clash template installed"
    else
        msg_err "clash.yaml download failed (non-fatal — panel serves native Clash sub)"
    fi
}

install_fake_site() {
    mkdir -p /var/www/html
    local idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
    local site_id; site_id=$(printf "site-%02d" "$idx")
    if curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/fake-sites/${site_id}/index.html" -o /var/www/html/index.html; then
        chmod 644 /var/www/html/index.html
        msg_ok "Decoy site '${site_id}' installed"
    else
        echo '<html><body></body></html>' > /var/www/html/index.html
    fi
}

install_diagnostics() {
    local webroot="/var/www/diagnostics"
    local backend_dir="/usr/local/lib/lucx-pro"
    mkdir -p "$webroot/testfiles" "$backend_dir"
    curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/diagnostics/index.html" -o "${webroot}/index.html" || true
    sed -i "s|__DIAG_PATH__|${diag_path}|g; s|__SERVER_DOMAIN__|${domain}|g; s|__SERVER_IP__|${IP4}|g" "${webroot}/index.html" 2>/dev/null || true
    curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/diagnostics/librespeed/speedtest.js" -o "${webroot}/speedtest.js" || true
    curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/diagnostics/librespeed/speedtest_worker.js" -o "${webroot}/speedtest_worker.js" || true
    dd if=/dev/zero bs=1048576 count=100 of="${webroot}/testfiles/test-100m.bin" status=none
    curl -fsSL --max-time 20 "${GITHUB_RAW}/pro-assets/diagnostics/mtr-backend.py" -o "${backend_dir}/mtr-backend.py" || true
    [[ -s "${backend_dir}/mtr-backend.py" ]] || printf '#!/usr/bin/env python3\nprint("mtr-backend placeholder")\n' > "${backend_dir}/mtr-backend.py"
    chmod 755 "${backend_dir}/mtr-backend.py"
    command -v setcap >/dev/null && setcap cap_net_raw+ep "$(command -v mtr-packet 2>/dev/null || command -v mtr)" 2>/dev/null || true
    id mtr-backend &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    MTR_BACKEND_PORT="$mtr_backend_port"
    cat > /etc/systemd/system/mtr-backend.service <<MTRUNIT
[Unit]
Description=lucx-pro MTR diagnostics backend
After=network.target
[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${backend_dir}/mtr-backend.py --port ${MTR_BACKEND_PORT}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
[Install]
WantedBy=multi-user.target
MTRUNIT
    systemctl daemon-reload && systemctl enable mtr-backend >/dev/null 2>&1 && systemctl restart mtr-backend
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    msg_ok "diagnostics: https://${domain}/${panel_path}/diag (SSO через логин панели)"
}

setup_cron() {
    crontab -l 2>/dev/null | grep -vE 'certbot|x-ui' | crontab -
    (crontab -l 2>/dev/null; echo '@daily   x-ui restart > /dev/null 2>&1 && nginx -s reload') | crontab -
    (crontab -l 2>/dev/null; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -
}

setup_firewall() {
    ufw disable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow "${hys_port}/udp"     comment hysteria2
    ufw allow "${mtproto_port}/tcp" comment mtproto
    ufw allow "${naive_port}/tcp"   comment naiveproxy
    ufw allow "${trust_port}/tcp"   comment trusttunnel
    ufw allow "${mieru_port}/tcp"   comment mieru
    ufw allow 56000:56003/udp       comment qwdtt
    ufw --force enable >/dev/null
    msg_ok "firewall: 22/80/443 tcp+udp + protocol ports"
}

show_results() {
    clear
    local B='\e[1;36m' G='\e[1;32m' R='\e[0m'
    msg_inf "──────────────────────────────────────────────────────────"
    msg_inf "  ✅  LucX-UI PRO installed"
    msg_inf "──────────────────────────────────────────────────────────"
    echo -e "  Panel:        ${G}https://${domain}/${panel_path}/${R}"
    echo -e "  Username:     ${config_username}"
    echo -e "  Password:     ${config_password}"
    msg_inf "──────────────────────────────────────────────────────────"
    echo -e "  Subscriptions (client: ${CLIENT_EMAIL}):"
    echo -e "   • Base64 (Happ/v2rayN/Incy): ${B}https://${domain}/${sub_path}/${CLIENT_SUBID}${R}"
    echo -e "   • Clash/Mihomo (UA-auto):    same URL, or:"
    echo -e "     ${B}https://${domain}/${clash_path}/${CLIENT_SUBID}${R}"
    echo -e "   • JSON (sing-box/karing):    ${B}https://${domain}/${json_path}/${CLIENT_SUBID}${R}"
    echo -e "   • AmneziaWG (/awg/):         ${B}https://${domain}/${awg_path}/${CLIENT_SUBID}${R}"
    echo -e "  Routing: Happ+Incy RoscomVPN profile «default» включён"
    msg_inf "──────────────────────────────────────────────────────────"
    echo -e "  Diagnostics:  https://${domain}/${panel_path}/diag"
    echo -e "  REALITY dom:  ${reality_domain}  (Vision @ :443)"
    echo -e "  Hysteria2:    ${IP4}:${hys_port} (udp)"
    echo -e "  MTProto:      ${domain}:${mtproto_port}"
    echo -e "  Naive:        ${domain}:${naive_port} · TT: ${domain}:${trust_port}"
    echo -e "  mieru:        ${domain}:${mieru_port} · qWDTT: udp 56000-56003"
    msg_inf "──────────────────────────────────────────────────────────"
    msg_inf "  ⚠ Sidecar-протоколы (Naive/TT/mieru/qWDTT/olcRTC): скачайте"
    msg_inf "    бинарь в Панель → Tunnels (одна кнопка) — после этого они стартуют."
    msg_inf "  Сохраните этот экран!"
}

main() {
    validate_domains
    clean_previous_install
    install_packages
    get_ssl_certs
    install_panel
    configure_nginx
    configure_xui_db
    install_clash_sub
    install_fake_site
    install_diagnostics
    tune_system
    setup_cron
    setup_firewall
    x-ui restart 2>/dev/null || true
    sleep 2
    show_results
}

tune_system() {
    local params=(
        "net.core.default_qdisc=fq"
        "net.ipv4.tcp_congestion_control=bbr"
        "fs.file-max=2097152"
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
    )
    for p in "${params[@]}"; do
        grep -qxF "$p" /etc/sysctl.conf || echo "$p" >> /etc/sysctl.conf
    done
    sysctl -p >/dev/null 2>&1
}

main
