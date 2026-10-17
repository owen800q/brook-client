#!/bin/sh
# Data-path test of the LAN-bypass design in an isolated Docker lab (Linux).
# Does not touch the host's network or VPN. Usage: Tests/docker/run.sh
set -eu
cd "$(dirname "$0")"
[ -x bin/brook ] && [ -x bin/tun2socks ] || {
	mkdir -p bin
	curl -fsSL -o bin/brook https://github.com/txthinking/brook/releases/download/v20270101/brook_linux_arm64
	curl -fsSL -o /tmp/t2s.zip https://github.com/xjasonlyu/tun2socks/releases/download/v2.7.0/tun2socks-linux-arm64.zip
	unzip -q -o /tmp/t2s.zip -d bin && mv bin/tun2socks-linux-arm64 bin/tun2socks
	chmod +x bin/brook bin/tun2socks
}
trap 'docker compose down -v --remove-orphans >/dev/null 2>&1' EXIT
docker compose up -d --build --wait >/dev/null 2>&1 || docker compose up -d --build
sleep 1
docker compose exec -T client sh /opt/client-test.sh
