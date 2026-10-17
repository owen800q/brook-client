FROM alpine:3.20
RUN apk add --no-cache iproute2 curl netcat-openbsd python3
COPY bin/brook bin/tun2socks /usr/local/bin/
COPY echo_server.py client-test.sh /opt/
