#!/bin/bash
set -e

# ============================================================
# Configuration from environment variables
# ============================================================
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASS="${VPN_PASS:-vpnpass}"
VPN_SERVER_NAME="${VPN_SERVER_NAME:-l2tpd}"
VPN_LOCAL_IP="${VPN_LOCAL_IP:-10.77.77.1}"
VPN_SUBNET="${VPN_LOCAL_IP%.*}.0/24"
VPN_IP_RANGE="${VPN_IP_RANGE:-10.77.77.10-10.77.77.100}"
VPN_DNS1="${VPN_DNS1:-8.8.8.8}"
VPN_DNS2="${VPN_DNS2:-8.8.4.4}"
VPN_TABLE_ID="${VPN_TABLE_ID:-100}"
TUN2SOCKS_LOGLEVEL="${TUN2SOCKS_LOGLEVEL:-warn}"
IPSEC_PSK="${IPSEC_PSK:-}"
BYPASS_CIDRS="${BYPASS_CIDRS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8}"
BYPASS_EXCLUDE="${BYPASS_EXCLUDE:-}"
VPN_MTU="${VPN_MTU:-$([ -n "${IPSEC_PSK}" ] && echo 1350 || echo 1400)}"
UDP_RELAY="${UDP_RELAY:-1}"

echo "=== L2TP VPN Server with SOCKS5 Proxy ==="
echo "SOCKS proxy: ${SOCKS_HOST}:${SOCKS_PORT}"
echo "VPN user: ${VPN_USER}"
echo "VPN IP range: ${VPN_IP_RANGE}"
echo "VPN local IP: ${VPN_LOCAL_IP}"
echo "IPsec: $([ -n "${IPSEC_PSK}" ] && echo "enabled" || echo "disabled")"

# Clean up global routing/iptables state (idempotent, safe to call multiple times)
cleanup_rules() {
    # Clean up ip rules and routing table
    while ip rule del fwmark 0x1338 table $VPN_TABLE_ID 2>/dev/null; do :; done
    ip route flush table $VPN_TABLE_ID 2>/dev/null || true

    # Clean up iptables FORWARD rules
    iptables -D FORWARD -i ppp+ -o tun0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i tun0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # Clean up iptables mangle/MSS clamping
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    # Clean up iptables NAT rules
    iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o eth0 -j MASQUERADE 2>/dev/null || true

    # Clean up IPsec iptables rules
    if [ -n "${IPSEC_PSK}" ]; then
        iptables -D INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p esp -j ACCEPT 2>/dev/null || true
    fi
}

# Clean up any residual state from previous ungraceful exit
cleanup_rules

# ============================================================
# Generate xl2tpd.conf
# ============================================================
if [ ! -f /etc/xl2tpd/xl2tpd.conf ]; then
    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = ${VPN_IP_RANGE}
local ip = ${VPN_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = no
name = ${VPN_SERVER_NAME}
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
    echo "[+] xl2tpd.conf generated"
else
    echo "[+] Using custom xl2tpd.conf"
fi

# ============================================================
# Generate chap-secrets
# ============================================================
if [ ! -f /etc/ppp/chap-secrets ]; then
    cat > /etc/ppp/chap-secrets <<EOF
${VPN_USER} ${VPN_SERVER_NAME} ${VPN_PASS} *
EOF
    chmod 600 /etc/ppp/chap-secrets
    echo "[+] chap-secrets generated"
else
    chmod 600 /etc/ppp/chap-secrets
    echo "[+] Using custom chap-secrets"
fi

# ============================================================
# Generate PPP options
# ============================================================
if [ ! -f /etc/ppp/options.xl2tpd ]; then
    cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
noauth
refuse-eap
require-chap
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}
asyncmap 0
mtu ${VPN_MTU}
mru ${VPN_MTU}
nodefaultroute
proxyarp
noccp
novj
nopcomp
noaccomp
lcp-echo-interval 15
lcp-echo-failure 3
logfd 1
EOF
    echo "[+] PPP options generated"
else
    echo "[+] Using custom PPP options"
fi

# ============================================================
# IPsec (strongSwan) — only when IPSEC_PSK is set
# ============================================================
if [ -n "${IPSEC_PSK}" ]; then
    echo "[+] IPsec enabled, generating strongSwan config..."

    if [ ! -f /etc/ipsec.conf ]; then
        cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=replace

conn %default
    keyingtries=5
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048,aes128-sha1-modp2048!
    esp=aes256-sha256,aes128-sha256,aes256-sha1,aes128-sha1!

conn l2tp-ipsec
    authby=secret
    auto=add
    keyingtries=3
    rekey=no
    ikelifetime=8h
    lifetime=1h
    type=transport
    left=%any
    leftprotoport=udp/1701
    right=%any
    rightprotoport=udp/%any
EOF
    else
        echo "[+] Using custom ipsec.conf"
    fi

    if [ ! -f /etc/ipsec.secrets ]; then
        cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "${IPSEC_PSK}"
EOF
        chmod 600 /etc/ipsec.secrets
    else
        chmod 600 /etc/ipsec.secrets
        echo "[+] Using custom ipsec.secrets"
    fi

    if [ ! -f /etc/strongswan.conf ]; then
        cat > /etc/strongswan.conf <<EOF
charon {
    load_modular = yes
    i_dont_care_about_security_and_use_aggressive_mode_psk = yes
    compress = yes
    plugins {
        duplicheck {
            enable = no
        }
        include strongswan.d/charon/*.conf
    }
}
EOF
    else
        echo "[+] Using custom strongswan.conf"
    fi
    echo "[+] strongSwan config generated"
else
    echo "[+] IPsec disabled (IPSEC_PSK not set), running in plain L2TP mode"
fi

# ============================================================
# Define VPN routing table
# ============================================================
grep -q "^${VPN_TABLE_ID} " /etc/iproute2/rt_tables 2>/dev/null || echo "${VPN_TABLE_ID} vpn" >> /etc/iproute2/rt_tables
echo "[+] Routing table 'vpn' ($VPN_TABLE_ID) defined"

# ============================================================
# Create ip-up/ip-down scripts for dynamic routing
# pppd calls these when PPP interface comes up/goes down
# $1=interface $2=tty $3=speed $4=local-ip $5=remote-ip $6=ipparam
# ============================================================
mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d

cat > /etc/ppp/ip-up.d/01-route-vpn <<SCRIPT
#!/bin/bash
IFACE="\$1"
LOCAL_IP="\$4"
REMOTE_IP="\$5"

cidr_to_range() {
    local ip mask bits host_max
    IFS='/' read -r ip mask <<< "\$1"
    local a b c d
    IFS='.' read -r a b c d <<< "\$ip"
    local num=\$(( (a << 24) + (b << 16) + (c << 8) + d ))
    bits=\$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
    local start=\$(( num & bits ))
    host_max=\$(( (1 << (32 - mask)) - 1 ))
    local end=\$(( start | host_max ))
    echo "\$(( (start >> 24) & 0xFF )).\$(( (start >> 16) & 0xFF )).\$(( (start >> 8) & 0xFF )).\$(( start & 0xFF ))-\$(( (end >> 24) & 0xFF )).\$(( (end >> 16) & 0xFF )).\$(( (end >> 8) & 0xFF )).\$(( end & 0xFF ))"
}

# Build exclude args: -m iprange ! --dst-range START-END for each BYPASS_EXCLUDE
EXCLUDE_ARGS=""
for ex in ${BYPASS_EXCLUDE//,/ }; do
    [ -z "\$ex" ] && continue
    EXCLUDE_ARGS="\$EXCLUDE_ARGS -m iprange ! --dst-range \$(cidr_to_range "\$ex")"
done

# Clean up any stale rules first (loop to remove all duplicates)
while ip rule del fwmark 0x1338 table $VPN_TABLE_ID 2>/dev/null; do :; done
while ip rule del iif "\$IFACE" table $VPN_TABLE_ID 2>/dev/null; do :; done
ip route flush table $VPN_TABLE_ID 2>/dev/null || true

# Mark bypass CIDRs with 0x1337 (direct route, skip SOCKS proxy)
# 0x1337 is not used for routing — it's a guard flag for the 0x1338 rules below,
# preventing bypass CIDR traffic from being sent through SOCKS proxy
for cidr in ${BYPASS_CIDRS//,/ }; do
    iptables -t mangle -D PREROUTING -i "\$IFACE" -d "\$cidr" \$EXCLUDE_ARGS -j MARK --set-mark 0x1337 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i "\$IFACE" -d "\$cidr" \$EXCLUDE_ARGS -j MARK --set-mark 0x1337
done

# Bypass traceroute UDP packets (SOCKS5 can't relay TTL mechanism)
iptables -t mangle -D PREROUTING -i "\$IFACE" -p udp --dport 33434:33534 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "\$IFACE" -p udp --dport 33434:33534 -j MARK --set-mark 0x1337

# Mark TCP/UDP with 0x1338 for SOCKS proxy routing, skipping packets already
# marked 0x1337 (bypass CIDRs). This two-step approach avoids combining
# multiple iprange negations in a single rule.
iptables -t mangle -D PREROUTING -i "\$IFACE" -p tcp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "\$IFACE" -p tcp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338
if [ "${UDP_RELAY}" = "1" ]; then
    iptables -t mangle -D PREROUTING -i "\$IFACE" -p udp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i "\$IFACE" -p udp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338
fi

# Policy routing: only TCP/UDP (fwmark 0x1338) goes through SOCKS proxy
# Everything else (bypass CIDRs, ICMP, etc.) falls through to main table
ip rule add fwmark 0x1338 table $VPN_TABLE_ID priority 150 2>/dev/null || true
ip route add default dev tun0 table $VPN_TABLE_ID 2>/dev/null || true

echo "[ip-up] \$IFACE: local=\$LOCAL_IP remote=\$REMOTE_IP, routing configured"
SCRIPT
chmod +x /etc/ppp/ip-up.d/01-route-vpn

cat > /etc/ppp/ip-down.d/01-route-vpn <<SCRIPT
#!/bin/bash
IFACE="\$1"

cidr_to_range() {
    local ip mask bits host_max
    IFS='/' read -r ip mask <<< "\$1"
    local a b c d
    IFS='.' read -r a b c d <<< "\$ip"
    local num=\$(( (a << 24) + (b << 16) + (c << 8) + d ))
    bits=\$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
    local start=\$(( num & bits ))
    host_max=\$(( (1 << (32 - mask)) - 1 ))
    local end=\$(( start | host_max ))
    echo "\$(( (start >> 24) & 0xFF )).\$(( (start >> 16) & 0xFF )).\$(( (start >> 8) & 0xFF )).\$(( start & 0xFF ))-\$(( (end >> 24) & 0xFF )).\$(( (end >> 16) & 0xFF )).\$(( (end >> 8) & 0xFF )).\$(( end & 0xFF ))"
}

# Build exclude args: -m iprange ! --dst-range START-END for each BYPASS_EXCLUDE
EXCLUDE_ARGS=""
for ex in ${BYPASS_EXCLUDE//,/ }; do
    [ -z "\$ex" ] && continue
    EXCLUDE_ARGS="\$EXCLUDE_ARGS -m iprange ! --dst-range \$(cidr_to_range "\$ex")"
done

# Only clean up mangle rules (interface-bound, safe to remove)
# ip rules and vpn table are global — let ip-up handle them
for cidr in ${BYPASS_CIDRS//,/ }; do
    iptables -t mangle -D PREROUTING -i "\$IFACE" -d "\$cidr" \$EXCLUDE_ARGS -j MARK --set-mark 0x1337 2>/dev/null || true
done
iptables -t mangle -D PREROUTING -i "\$IFACE" -p udp --dport 33434:33534 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -p tcp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338 2>/dev/null || true
if [ "${UDP_RELAY}" = "1" ]; then
    iptables -t mangle -D PREROUTING -i "\$IFACE" -p udp -m mark ! --mark 0x1337 -j MARK --set-mark 0x1338 2>/dev/null || true
fi

echo "[ip-down] \$IFACE: mangle rules cleaned up"
SCRIPT
chmod +x /etc/ppp/ip-down.d/01-route-vpn

echo "[+] ip-up/ip-down scripts created"

# ============================================================
# Enable IP forwarding
# ============================================================
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "[+] IP forwarding already enabled"
else
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || {
        echo "[!] ERROR: IP forwarding is disabled and cannot be enabled."
        echo "    Start with --privileged or set host: sysctl -w net.ipv4.ip_forward=1"
        exit 1
    }
fi

# ============================================================
# Create xl2tpd control socket directory
# ============================================================
mkdir -p /var/run/xl2tpd

# ============================================================
# Start strongSwan (IPsec)
# ============================================================
if [ -n "${IPSEC_PSK}" ]; then
    echo "[+] Starting strongSwan..."
    ipsec start
    sleep 2
    CHARON_PID=$(cat /var/run/charon.pid 2>/dev/null || echo "")
    ipsec status || true
    echo "[+] strongSwan started (charon PID: $CHARON_PID)"
fi

# ============================================================
# Generate hev-socks5-tunnel config
# ============================================================
SOCKS5_AUTH=""
if [ -n "${SOCKS_USER}" ]; then
    SOCKS5_AUTH="  username: '${SOCKS_USER}'
  password: '${SOCKS_PASS}'"
fi

TUN2SOCKS_CONF="/etc/hev-socks5-tunnel.yaml"
if [ ! -f "$TUN2SOCKS_CONF" ]; then
    cat > "$TUN2SOCKS_CONF" <<EOF
tunnel:
  name: tun0
  mtu: ${VPN_MTU}
  ipv4: 198.18.0.1
  multi-queue: true

socks5:
  port: ${SOCKS_PORT}
  address: ${SOCKS_HOST}
  udp: 'udp'
  pipeline: true
  tcp-fastopen: true
${SOCKS5_AUTH}

misc:
  log-level: ${TUN2SOCKS_LOGLEVEL}
  log-file: stdout
EOF
    echo "[+] hev-socks5-tunnel config generated"
else
    echo "[+] Using custom hev-socks5-tunnel config"
fi

# ============================================================
# Start hev-socks5-tunnel
# ============================================================
echo "[+] Starting hev-socks5-tunnel..."
hev-socks5-tunnel /etc/hev-socks5-tunnel.yaml &
HEV_PID=$!

# Wait for tun0 to appear
for i in $(seq 1 10); do ip link show tun0 &>/dev/null && break; sleep 0.5; done
ip link set tun0 up
ip link set tun0 txqueuelen 2000

# Allow forwarding from ppp+ to tun0 (FORWARD chain default is DROP on many hosts)
iptables -A FORWARD -i ppp+ -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT
# TCP MSS clamping: avoid fragmentation across PPP/L2TP/IPsec encapsulation
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# NAT: tun0 outbound (SOCKS proxy traffic)
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
# NAT: VPN client to local/Docker network (so replies route back via container)
iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o eth0 -j MASQUERADE
# IPsec iptables rules
if [ -n "${IPSEC_PSK}" ]; then
    iptables -A INPUT -p udp --dport 500 -j ACCEPT
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT -p esp -j ACCEPT
fi
echo "[+] hev-socks5-tunnel started (PID: $HEV_PID), tun0 UP, NAT configured"

# ============================================================
# Start xl2tpd
# ============================================================
echo "[+] Starting xl2tpd..."
xl2tpd -D &
XL2TPD_PID=$!
echo "[+] xl2tpd started (PID: $XL2TPD_PID)"
echo "=== VPN Server is running, waiting for connections on UDP 1701 ==="

shutdown() {
    echo "[!] Shutting down..."
    kill "$HEV_PID" "$XL2TPD_PID" 2>/dev/null || true
    [ -n "$CHARON_PID" ] && kill -0 "$CHARON_PID" 2>/dev/null && kill "$CHARON_PID" 2>/dev/null || true
    cleanup_rules
    wait
    exit 0
}
trap shutdown SIGTERM SIGINT USR1

# Monitor charon (not a child of this shell, can't use wait -n)
if [ -n "$CHARON_PID" ]; then
    (
        while kill -0 "$CHARON_PID" 2>/dev/null; do sleep 5; done
        echo "[!] charon exited"
        kill -USR1 $$
    ) &
fi

wait -n $HEV_PID $XL2TPD_PID
echo "[!] A critical process exited, shutting down..."
shutdown
