FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    xl2tpd \
    ppp \
    iproute2 \
    iptables \
    curl \
    ca-certificates \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install tun2socks
ARG TUN2SOCKS_VERSION=v2.6.0
RUN curl -fsSL -o /tmp/tun2socks.zip \
    "https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/tun2socks-linux-amd64-v3.zip" \
    && unzip /tmp/tun2socks.zip -d /usr/local/bin/ \
    && mv /usr/local/bin/tun2socks-linux-amd64-v3 /usr/local/bin/tun2socks \
    && chmod +x /usr/local/bin/tun2socks \
    && rm /tmp/tun2socks.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1701/udp

ENTRYPOINT ["/entrypoint.sh"]
