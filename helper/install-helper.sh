#!/bin/sh
# Installs (or removes) Brook Client's privileged pieces. Run as root, e.g. via
#   osascript -e 'do shell script "... install-helper.sh install <srcdir> <user>" with administrator privileges'
#
#   install <dir containing brook-client-helper and tun2socks> <username>
#   uninstall
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

DEST=/Library/PrivilegedHelperTools
HELPER=$DEST/com.brookclient.helper
TUN2SOCKS=$DEST/com.brookclient.tun2socks
SUDOERS=/etc/sudoers.d/com.brookclient

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

case ${1:-} in
install)
	src=${2:?source dir}
	user=${3:?username}
	case $user in '' | *[!A-Za-z0-9._-]*) echo "bad username" >&2; exit 2 ;; esac
	id "$user" >/dev/null 2>&1 || { echo "no such user" >&2; exit 2; }
	[ -f "$src/brook-client-helper" ] && [ -f "$src/tun2socks" ] || { echo "missing files in $src" >&2; exit 1; }

	# Stop a running tunnel from an older helper before replacing it.
	[ -x "$HELPER" ] && "$HELPER" down >/dev/null 2>&1 || true

	mkdir -p "$DEST"
	install -o root -g wheel -m 755 "$src/brook-client-helper" "$HELPER"
	install -o root -g wheel -m 755 "$src/tun2socks" "$TUN2SOCKS"

	tmp=$(mktemp /tmp/com.brookclient.sudoers.XXXXXX)
	printf '# Brook Client: lets %s manage the VPN tunnel without a password prompt.\n%s ALL=(root) NOPASSWD: %s\n' \
		"$user" "$user" "$HELPER" >"$tmp"
	if ! visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; echo "sudoers validation failed" >&2; exit 1; fi
	install -o root -g wheel -m 440 "$tmp" "$SUDOERS"
	rm -f "$tmp"
	echo installed
	;;
uninstall)
	[ -x "$HELPER" ] && "$HELPER" down >/dev/null 2>&1 || true
	rm -f "$SUDOERS" "$HELPER" "$TUN2SOCKS"
	rm -rf /var/run/com.brookclient
	echo uninstalled
	;;
*)
	echo "usage: $0 install <srcdir> <user> | uninstall" >&2
	exit 2
	;;
esac
