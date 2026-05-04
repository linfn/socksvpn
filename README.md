# socksvpn

Plain L2TP VPN Server (no IPsec) that transparently forwards all client traffic through an external SOCKS5 proxy via [tun2socks](https://github.com/xjasonlyu/tun2socks).

> **Note**: Only bare L2TP is supported. L2TP/IPsec is not supported — no IPsec daemon is included.

```
VPN Client ──L2TP──▶ xl2tpd ──ppp0──▶ Policy Routing ──tun0──▶ tun2socks ──▶ SOCKS5 Proxy ──▶ Internet
```

- Public IP traffic exits through the SOCKS5 proxy
- Private IP traffic (10.x / 172.16-31.x / 192.168.x) routes directly
- DNS queries also go through the SOCKS5 proxy

## Quick Start

```bash
docker run -d --name socksvpn \
    --init \
    --restart=always \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --device=/dev/ppp \
    -p 1701:1701/udp \
    -e SOCKS5_HOST=your_socks5_host \
    -e SOCKS5_PORT=1080 \
    -e VPN_USER=myuser \
    -e VPN_PASS=mypassword \
    linfn/socksvpn
```

Connect your VPN client to the host IP using **L2TP** (without IPsec) + CHAP authentication.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SOCKS5_HOST` | `127.0.0.1` | SOCKS5 proxy host |
| `SOCKS5_PORT` | `1080` | SOCKS5 proxy port |
| `VPN_USER` | `vpnuser` | VPN username |
| `VPN_PASS` | `vpnpass` | VPN password |
| `VPN_SERVER_NAME` | `l2tpd` | PPP auth server name |
| `VPN_LOCAL_IP` | `10.77.77.1` | VPN server IP |
| `VPN_IP_RANGE` | `10.77.77.10-10.77.77.100` | Client IP address pool |
| `VPN_DNS1` | `8.8.8.8` | Primary DNS |
| `VPN_DNS2` | `8.8.4.4` | Secondary DNS |
| `VPN_TABLE_ID` | `100` | Policy routing table ID |
| `TUN2SOCKS_LOGLEVEL` | `warn` | tun2socks log level (debug/info/warn/error) |

## Docker Network

Use a custom bridge network so the VPN container can reach the SOCKS5 proxy by name:

```bash
docker network create mynet

# SOCKS5 proxy container
docker run -d --name socks5 --network mynet ...

# VPN server
docker run -d --name socksvpn --network mynet \
    --init --restart=always \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --device=/dev/ppp \
    -p 1701:1701/udp \
    -e SOCKS5_HOST=socks5 \
    -e SOCKS5_PORT=1080 \
    -e VPN_USER=myuser \
    -e VPN_PASS=mypassword \
    linfn/socksvpn
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Docker Container                    │
│                                                      │
│  xl2tpd (UDP 1701)                                   │
│      │                                               │
│      ▼                                               │
│  ppp0 (VPN client session)                           │
│      │                                               │
│      ├─ private IP ─▶ fwmark ─▶ main table ─▶ eth0   │
│      │                                               │
│      └─ public IP  ─▶ vpn table ─▶ tun0 ─▶ tun2socks │
│                                                      │
└─────────────────────────────────────────────────────┘
```

- iptables mangle marks packets destined for private IPs (fwmark 0x1337)
- Policy routing: fwmark rule (priority 100) takes precedence over iif rule (priority 200)
- All rules live in the container's network namespace — no side effects on the host

## License

MIT
