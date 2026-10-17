#!/bin/sh
# Runs inside the client container. Applies the same routing plan the macOS helper applies
# (Linux `ip` instead of BSD `route`), then checks where traffic actually goes.
set -u
SERVER=203.0.113.2
GW=203.0.113.1
WEB=198.51.100.80
TV=192.168.50.20
GHOST=192.168.50.250 # nothing lives here
BYPASS_NET="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
BYPASS_LINK="169.254.0.0/16 224.0.0.0/4"

fails=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
iface_for() { ip -o -4 addr show | awk -v ip="$1" 'index($4, ip "/") == 1 { print $2 }'; }
WAN_IF=$(iface_for 203.0.113.10)
LAN_IF=$(iface_for 192.168.50.10)

ip route replace default via $GW dev "$WAN_IF"

echo "== 0. isolation: without the tunnel the 'internet' is unreachable"
if curl -s -m 3 "http://$WEB/" >/dev/null; then fail "web reachable without tunnel (lab broken)"; else pass "web unreachable without tunnel"; fi

echo "== 1. bring up: same order as the helper (server + bypass routes before catch-all)"
ip route add $SERVER/32 via $GW dev "$WAN_IF" 2>/dev/null || true
for n in $BYPASS_NET; do ip route add "$n" via $GW dev "$WAN_IF"; done
for n in $BYPASS_LINK; do ip route add "$n" dev "$WAN_IF"; done
brook connect --link "$(brook link -s $SERVER:9999 -p labpass)" --socks5 127.0.0.1:1080 >/tmp/brook.log 2>&1 &
sleep 1
tun2socks --device tun0 --proxy socks5://127.0.0.1:1080 --loglevel warn >/tmp/t2s.log 2>&1 &
i=0; until ip link show tun0 >/dev/null 2>&1 || [ $i -gt 50 ]; do sleep 0.1; i=$((i + 1)); done
ip addr add 198.18.0.1/32 dev tun0
ip link set tun0 up
ip route add 0.0.0.0/1 dev tun0
ip route add 128.0.0.0/1 dev tun0
ip -4 route | sed 's/^/        /'

echo "== 2. internet traffic goes through brook"
seen=$(curl -s -m 5 "http://$WEB/")
[ "$seen" = 198.51.100.2 ] && pass "web sees brook server ($seen) => tunneled" || fail "web saw '$seen'"
udp=$(timeout 8 brook echoclient -s $WEB:7777 2>&1)
echo "$udp" | grep -qi udp && echo "$udp" | grep -q 198.51.100.2 &&
	pass "UDP tunneled too (echoserver saw 198.51.100.2)" || fail "UDP: $udp"

echo "== 3. home LAN bypasses the VPN (the sdb/TV case)"
dev=$(ip route get $TV | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ "$dev" = "$LAN_IF" ] && pass "route to TV: dev $dev (LAN, not tun0)" || fail "route to TV via $dev"
seen=$(curl -s -m 5 "http://$TV:26101/")
[ "$seen" = 192.168.50.10 ] && pass "TV:26101 reachable, sees our LAN IP ($seen) => direct" || fail "TV saw '$seen'"
if nc -z -w 3 $GHOST 4321 2>/dev/null; then fail "nonexistent $GHOST:4321 accepted (hijacked)"; else pass "nonexistent $GHOST:4321 refused/timed out (no fake accept)"; fi

echo "== 4. control: route the LAN into the tunnel like the official client does"
ip route add 192.168.50.0/25 dev tun0
ip route add 192.168.50.128/25 dev tun0
if nc -z -w 3 $GHOST 4321 2>/dev/null; then pass "bug reproduced: nonexistent $GHOST accepted via tunnel"; else fail "control did not reproduce bug"; fi
if curl -s -m 5 "http://$TV:26101/" | grep -q .; then fail "TV still reachable in control"; else pass "bug reproduced: TV unreachable when LAN is tunneled"; fi
ip route del 192.168.50.0/25 dev tun0
ip route del 192.168.50.128/25 dev tun0

echo "== 5. memory (RSS)"
for p in brook tun2socks; do
	pid=$(pgrep -x $p | head -1)
	echo "        $p: $(awk '/VmRSS/ {printf "%.1f MB", $2/1024}' /proc/$pid/status)"
done

echo "== result: $fails failure(s)"
[ $fails = 0 ]
