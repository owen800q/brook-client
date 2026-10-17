# Brook Client

A lightweight macOS menu-bar client for [Brook](https://github.com/txthinking/brook) that **keeps your home network (LAN) outside the VPN**, so tools like Samsung's `sdb` can reach your TV while the VPN is connected.

## Why

With the official Brook app connected, every LAN connection is hijacked by its tunnel: even a non-existent host such as `192.168.0.250` "accepts" TCP connections, because the tunnel's userspace TCP stack completes the handshake itself. `sdb connect <tv-ip>` therefore talks to a fake endpoint, and installing the app fails.

This client routes explicitly instead:

| Destination | Route |
|---|---|
| Brook server IP(s) | physical gateway (host route) |
| Bypass list (default `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `224/4`) | physical gateway / on-link, **never the tunnel** |
| Everything else (`0/1`, `128/1`) | `utun` → tun2socks → `brook connect` (SOCKS5) → server |
| Public IPv6 (`2000::/3`) | rejected (optional, prevents leaks; apps fall back to IPv4) |

LAN traffic is routed by the kernel directly; it never reaches any userspace stack.

## Memory

| Process | Footprint |
|---|---|
| Brook Client (menu bar, idle) | ~12 MB (settings window adds ~28 MB while open, freed on close) |
| `brook connect` | ~15 MB RSS |
| `tun2socks` (TUN mode only) | ~15–20 MB RSS |

## Build & install

```sh
brew install brook
scripts/build-app.sh --install     # → ~/Applications/Brook Client.app (downloads tun2socks v2.7.0 once)
swift test                         # 58 tests: link parsing, CIDRs, routing plan, config, root helper (dry-run)
Tests/docker/run.sh                # end-to-end data-path lab in Docker (doesn't touch the host network)
```

`Tests/docker` builds three isolated networks: a home LAN with a fake TV on `:26101`, a WAN with a brook server, and an "internet" that only the server can reach. It runs the real brook and tun2socks with the same route plan as the helper, using Linux `ip` instead of BSD `route`. It checks the following:
- Internet TCP and UDP exit via the brook server.
- The TV is reached directly from the LAN IP.
- A nonexistent LAN host is **not** fake-accepted.
- The control step routes the LAN into the tunnel the way the official client does, and reproduces the bug.

The lab doesn't cover the macOS GUI or the helper itself.

## Use

1. **Disconnect the official Brook app** (the two would fight over routing; this client refuses to connect while another VPN holds the default route).
2. Open *Brook Client* → Settings → **Install…** network helper (admin password, once).
3. Copy your `brook://…` link, then click **Add Server**. The link is pasted from the clipboard.
4. Save, then **Connect** from the menu-bar shield.
5. Check the bypass:
   ```sh
   route -n get 192.168.0.128    # interface: en1 (not utun)
   nc -z -G2 192.168.0.250 4321  # should FAIL now (nothing there): no more fake accepts
   sdb connect <tv-ip>           # works
   curl https://ipinfo.io/ip      # your Brook server's IP
   ```

Modes:
- **Full device (TUN)** (default): every app is tunneled except the bypass list.
- **System proxy only**: sets the macOS HTTP/HTTPS/SOCKS proxy (bypass list included). It needs no TUN, and command-line tools are never proxied.

Supported link kinds: `server`, `wsserver`, `wssserver`, `quicserver` (`socks5` links are not usable with `brook connect`).

## How it's built

- `Sources/BrookCore`: pure, tested logic. It covers link parsing and IP pinning (brook dials exactly the IP that is routed outside the tunnel), CIDRs, gateway detection from `netstat`, helper-argument planning, and config.
- `Sources/BrookClient`: AppKit menu bar plus a SwiftUI settings window. It handles the process lifecycle, health checks, and auto-reconnect on brook exit or a network (Wi-Fi) change.
- `helper/brook-client-helper`: the only root code, POSIX `sh`. It is installed root-owned at `/Library/PrivilegedHelperTools/com.brookclient.helper` and allowed for your user only via `/etc/sudoers.d/com.brookclient`.
  - Every argument is re-validated. There is no `eval`, and globbing is off.
  - It writes an undo log under `/var/run/com.brookclient`.
  - A watchdog tears everything down (routes, DNS, proxy) if the app or tun2socks dies.
- `helper/install-helper.sh`: install / `uninstall` (run as root).

Config: `~/Library/Application Support/BrookClient/config.json` (mode 600; it contains your link). Logs: `~/Library/Logs/BrookClient/brook.log`, `/var/log/com.brookclient.log` (tun2socks).

### Uninstall

```sh
sudo sh ~/Applications/"Brook Client.app"/Contents/Resources/install-helper.sh uninstall
rm -rf ~/Applications/Brook\ Client.app ~/Library/Application\ Support/BrookClient
```

### Known limitations
- Only IPv4 is tunneled. Public IPv6 is blocked by default rather than tunneled.
- The brook link (including its password) appears in `brook connect`'s process arguments, as with the brook CLI itself.
