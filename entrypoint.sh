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
VPN_IP_RANGE="${VPN_IP_RANGE:-10.77.77.10-10.77.77.100}"
VPN_DNS1="${VPN_DNS1:-8.8.8.8}"
VPN_DNS2="${VPN_DNS2:-8.8.4.4}"
VPN_TABLE_ID="${VPN_TABLE_ID:-100}"
TUN2SOCKS_LOGLEVEL="${TUN2SOCKS_LOGLEVEL:-warn}"
IPSEC_PSK="${IPSEC_PSK:-}"

echo "=== L2TP VPN Server with SOCKS5 Proxy ==="
echo "SOCKS proxy: ${SOCKS_HOST}:${SOCKS_PORT}"
echo "VPN user: ${VPN_USER}"
echo "VPN IP range: ${VPN_IP_RANGE}"
echo "VPN local IP: ${VPN_LOCAL_IP}"
echo "IPsec: $([ -n "${IPSEC_PSK}" ] && echo "enabled" || echo "disabled")"

# ============================================================
# Generate xl2tpd.conf
# ============================================================
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
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
echo "[+] xl2tpd.conf generated"

# ============================================================
# Generate chap-secrets
# ============================================================
cat > /etc/ppp/chap-secrets <<EOF
${VPN_USER} ${VPN_SERVER_NAME} ${VPN_PASS} *
EOF
chmod 600 /etc/ppp/chap-secrets
echo "[+] chap-secrets generated"

# ============================================================
# Generate PPP options
# ============================================================
cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
noauth
refuse-eap
require-chap
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}
asyncmap 0
mtu 1400
mru 1400
nodefaultroute
proxyarp
lcp-echo-interval 30
lcp-echo-failure 3
connect-delay 5000
debug
logfd 1
EOF
echo "[+] PPP options generated"

# ============================================================
# IPsec (strongSwan) — only when IPSEC_PSK is set
# ============================================================
if [ -n "${IPSEC_PSK}" ]; then
    echo "[+] IPsec enabled, generating strongSwan config..."

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

    cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "${IPSEC_PSK}"
EOF
    chmod 600 /etc/ipsec.secrets

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

# Clean up any stale rules first (loop to remove all duplicates)
while ip rule del iif "\$IFACE" table $VPN_TABLE_ID 2>/dev/null; do :; done
while ip rule del fwmark 0x1337 table main 2>/dev/null; do :; done
ip route flush table $VPN_TABLE_ID 2>/dev/null || true

# Remove stale iptables rules (safe to call even if they don't exist)
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 10.0.0.0/8 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 172.16.0.0/12 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 192.168.0.0/16 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 127.0.0.0/8 -j MARK --set-mark 0x1337 2>/dev/null || true

# Add iptables mangle rules to mark private IP traffic
iptables -t mangle -A PREROUTING -i "\$IFACE" -d 10.0.0.0/8 -j MARK --set-mark 0x1337
iptables -t mangle -A PREROUTING -i "\$IFACE" -d 172.16.0.0/12 -j MARK --set-mark 0x1337
iptables -t mangle -A PREROUTING -i "\$IFACE" -d 192.168.0.0/16 -j MARK --set-mark 0x1337
iptables -t mangle -A PREROUTING -i "\$IFACE" -d 127.0.0.0/8 -j MARK --set-mark 0x1337

# Policy routing (fwmark must have higher priority than iif)
ip rule add fwmark 0x1337 table main priority 100
ip rule add iif "\$IFACE" table $VPN_TABLE_ID priority 200
ip route add default dev tun0 table $VPN_TABLE_ID

echo "[ip-up] \$IFACE: local=\$LOCAL_IP remote=\$REMOTE_IP, routing configured"
SCRIPT
chmod +x /etc/ppp/ip-up.d/01-route-vpn

cat > /etc/ppp/ip-down.d/01-route-vpn <<SCRIPT
#!/bin/bash
IFACE="\$1"

# Remove policy routing rules
ip rule del iif "\$IFACE" table $VPN_TABLE_ID 2>/dev/null || true
ip rule del fwmark 0x1337 table main 2>/dev/null || true

# Remove iptables mangle rules for this interface
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 10.0.0.0/8 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 172.16.0.0/12 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 192.168.0.0/16 -j MARK --set-mark 0x1337 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$IFACE" -d 127.0.0.0/8 -j MARK --set-mark 0x1337 2>/dev/null || true

# Flush vpn routing table
ip route flush table $VPN_TABLE_ID 2>/dev/null || true

echo "[ip-down] \$IFACE: routing cleaned up"
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
    ipsec status || true
    echo "[+] strongSwan started"
fi

# ============================================================
# Generate hev-socks5-tunnel config
# ============================================================
cat > /etc/hev-socks5-tunnel.yaml <<EOF
tunnel:
  name: tun0
  mtu: 1400
  ipv4: 198.18.0.1
  multi-queue: false

socks5:
  port: ${SOCKS_PORT}
  address: ${SOCKS_HOST}
  udp: 'udp'
EOF

if [ -n "${SOCKS_USER}" ]; then
    cat >> /etc/hev-socks5-tunnel.yaml <<EOF
  username: '${SOCKS_USER}'
  password: '${SOCKS_PASS}'
EOF
fi

cat >> /etc/hev-socks5-tunnel.yaml <<EOF
misc:
  log-level: ${TUN2SOCKS_LOGLEVEL}
  log-file: stdout
EOF
echo "[+] hev-socks5-tunnel config generated"

# ============================================================
# Start hev-socks5-tunnel
# ============================================================
echo "[+] Starting hev-socks5-tunnel..."
hev-socks5-tunnel /etc/hev-socks5-tunnel.yaml &
HEV_PID=$!

# Wait for tun0 to appear
for i in $(seq 1 10); do ip link show tun0 &>/dev/null && break; sleep 0.5; done
ip link set tun0 up

# Allow forwarding from ppp+ to tun0 (FORWARD chain default is DROP on many hosts)
iptables -A FORWARD -i ppp+ -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT
# TCP MSS clamping: avoid fragmentation across PPP/L2TP/IPsec encapsulation
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# NAT: tun0 outbound (SOCKS proxy traffic)
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
# NAT: VPN client to local/Docker network (so replies route back via container)
VPN_SUBNET="${VPN_LOCAL_IP%.*}.0/24"
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

wait $XL2TPD_PID
