#!/bin/bash
set -e

# ============================================================
# Configuration from environment variables
# ============================================================
SOCKS5_HOST="${SOCKS5_HOST:-127.0.0.1}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASS="${VPN_PASS:-vpnpass}"
VPN_SERVER_NAME="${VPN_SERVER_NAME:-l2tpd}"
VPN_LOCAL_IP="${VPN_LOCAL_IP:-10.10.10.1}"
VPN_IP_RANGE="${VPN_IP_RANGE:-10.10.10.10-10.10.10.100}"
VPN_DNS1="${VPN_DNS1:-8.8.8.8}"
VPN_DNS2="${VPN_DNS2:-8.8.4.4}"
VPN_TABLE_ID="${VPN_TABLE_ID:-100}"

echo "=== L2TP VPN Server with SOCKS5 Proxy ==="
echo "SOCKS5 proxy: ${SOCKS5_HOST}:${SOCKS5_PORT}"
echo "VPN user: ${VPN_USER}"
echo "VPN IP range: ${VPN_IP_RANGE}"
echo "VPN local IP: ${VPN_LOCAL_IP}"

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
connect-delay 5000
debug
logfd 1
EOF
echo "[+] PPP options generated"

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

# Policy routing
ip rule add fwmark 0x1337 table main
ip rule add iif "\$IFACE" table $VPN_TABLE_ID
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
# Start tun2socks
# ============================================================
echo "[+] Starting tun2socks..."
tun2socks -device tun0 -proxy "socks5://${SOCKS5_HOST}:${SOCKS5_PORT}" -loglevel warn &
TUN2SOCKS_PID=$!

# Wait for tun0 to appear
for i in $(seq 1 10); do ip link show tun0 &>/dev/null && break; sleep 0.5; done
ip link set tun0 up
ip addr add 198.18.0.1/16 dev tun0 2>/dev/null || true

# Allow forwarding from ppp+ to tun0 (FORWARD chain default is DROP on many hosts)
iptables -A FORWARD -i ppp+ -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

# Configure NAT for tun0 outbound traffic
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
echo "[+] tun2socks started (PID: $TUN2SOCKS_PID), tun0 UP, NAT configured"

# ============================================================
# Start xl2tpd
# ============================================================
echo "[+] Starting xl2tpd..."
xl2tpd -D &
XL2TPD_PID=$!
echo "[+] xl2tpd started (PID: $XL2TPD_PID)"
echo "=== VPN Server is running, waiting for connections on UDP 1701 ==="

# ============================================================
# Signal handling: kill child processes on exit
# iptables/route rules are in container namespace, auto-destroyed on exit
# ============================================================
cleanup() {
    echo "[!] Shutting down..."
    kill $XL2TPD_PID $TUN2SOCKS_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

wait $XL2TPD_PID
