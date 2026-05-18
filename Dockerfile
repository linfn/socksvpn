FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    xl2tpd \
    ppp \
    iproute2 \
    iptables \
    strongswan \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/xl2tpd/xl2tpd.conf \
             /etc/ppp/chap-secrets \
             /etc/ipsec.conf \
             /etc/ipsec.secrets \
             /etc/strongswan.conf

# Install hev-socks5-tunnel
ARG HEV_SOCKS5_TUNNEL_VERSION=2.14.4
ARG TARGETARCH
RUN ARCH=$TARGETARCH; \
    if [ "$ARCH" = "amd64" ]; then ARCH=x86_64; elif [ "$ARCH" = "arm" ]; then ARCH=arm32v7; fi; \
    curl -fsSL -o /usr/local/bin/hev-socks5-tunnel \
    "https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_SOCKS5_TUNNEL_VERSION}/hev-socks5-tunnel-linux-${ARCH}" \
    && chmod +x /usr/local/bin/hev-socks5-tunnel

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1701/udp 500/udp 4500/udp

ENTRYPOINT ["/entrypoint.sh"]
