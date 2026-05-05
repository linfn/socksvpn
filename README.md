# socksvpn

L2TP VPN Server that transparently forwards all client traffic through an external SOCKS5 proxy via [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel). Supports both plain L2TP and L2TP/IPsec modes.

```
VPN Client ──[strongSwan]──L2TP──▶ xl2tpd ──ppp0──▶ Policy Routing ──tun0──▶ hev-socks5-tunnel ──▶ SOCKS5 Proxy ──▶ Internet
             (optional)
```

- Public IP traffic exits through the SOCKS5 proxy
- Private IP traffic (10.x / 172.16-31.x / 192.168.x) routes directly
- DNS queries also go through the SOCKS5 proxy

## Quick Start

### Plain L2TP (default)

```bash
docker run -d --name socksvpn \
    --init \
    --restart=always \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --device=/dev/ppp \
    -p 1701:1701/udp \
    -e SOCKS_HOST=<socks_host> \
    -e SOCKS_PORT=<1080> \
    -e VPN_USER=<vpn_user> \
    -e VPN_PASS=<vpn_password> \
    linfn/socksvpn
```

### L2TP/IPsec

```bash
docker run -d --name socksvpn \
    --init \
    --restart=always \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --device=/dev/ppp \
    -p 1701:1701/udp \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -e SOCKS_HOST=<socks_host> \
    -e SOCKS_PORT=<1080> \
    -e VPN_USER=<vpn_user> \
    -e VPN_PASS=<vpn_password> \
    -e IPSEC_PSK=<pre_shared_key> \
    linfn/socksvpn
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SOCKS_HOST` | `127.0.0.1` | SOCKS proxy host |
| `SOCKS_PORT` | `1080` | SOCKS proxy port |
| `SOCKS_USER` | *(empty)* | SOCKS5 auth username (optional) |
| `SOCKS_PASS` | *(empty)* | SOCKS5 auth password (optional) |
| `VPN_USER` | `vpnuser` | VPN username |
| `VPN_PASS` | `vpnpass` | VPN password |
| `VPN_DNS1` | `8.8.8.8` | Primary DNS |
| `VPN_DNS2` | `8.8.4.4` | Secondary DNS |
| `IPSEC_PSK` | *(empty)* | Set to enable L2TP/IPsec with this pre-shared key |
| `TUN2SOCKS_LOGLEVEL` | `warn` | hev-socks5-tunnel log level (debug/info/warn/error) |

## Client Compatibility

| Platform | Plain L2TP | L2TP/IPsec |
|---|---|---|
| Routers | Xiaomi, TP-Link, ASUS, OpenWrt | Varies by model |
| macOS | Requires third-party app | Built-in (System Settings > VPN) |
| iOS | Requires third-party app | Built-in (Settings > VPN) |
| Windows | Manual config | Built-in |
| Android | Requires third-party app | Built-in (Settings > VPN) |
| Linux | xl2tpd + pppd | xl2tpd + strongSwan / NetworkManager |

> **macOS and iOS** only support L2TP/IPsec via the built-in client. Set `IPSEC_PSK` to enable.

## Architecture

```
┌───────────────────────────────────────────────────┐
│               Docker Container                    │
│                                                   │
│  [strongSwan] ← IPsec (optional, set IPSEC_PSK)   │
│      │                                            │
│      ▼                                            │
│  xl2tpd (UDP 1701)                                │
│      │                                            │
│      ▼                                            │
│  ppp0 (VPN client session)                        │
│      │                                            │
│      ├─ private IP ─▶ fwmark ─▶ main ─▶ eth0      │
│      │                                            │
│      └─ public IP ─▶ vpn table ─▶ tun2socks       │
│                                                   │
└───────────────────────────────────────────────────┘
```

- iptables mangle marks packets destined for private IPs (fwmark 0x1337)
- Policy routing: fwmark rule (priority 100) takes precedence over iif rule (priority 200)
- All rules live in the container's network namespace — no side effects on the host

## License

MIT
