import Darwin
import Foundation
import Testing
@testable import BrookCore

/// Corporate networks that only allow the internet through an HTTP proxy (HTTP CONNECT).
@Suite struct UpstreamProxyTests {
    // MARK: - Parsing

    @Test func parsesProxyForms() throws {
        #expect(try UpstreamProxy(parsing: "") == nil)
        #expect(try UpstreamProxy(parsing: "   ") == nil)
        #expect(try UpstreamProxy(parsing: "proxy.corp:8080") == UpstreamProxy(host: "proxy.corp", port: 8080))
        #expect(try UpstreamProxy(parsing: "http://10.1.2.3:3128/") == UpstreamProxy(host: "10.1.2.3", port: 3128))
        let auth = try #require(try UpstreamProxy(parsing: "http://dom%5Calice:p%40ss@proxy.corp:8080"))
        #expect(auth.username == "dom\\alice")
        #expect(auth.password == "p@ss")
        #expect(try UpstreamProxy(parsing: "proxy.corp:8080")?.hostIsIPv4 == false)
        #expect(try UpstreamProxy(parsing: "10.0.0.1:8080")?.hostIsIPv4 == true)
    }

    @Test func rejectsBadProxies() {
        for bad in ["proxy.corp", "socks5://proxy:1080", "https://proxy:443", "proxy:0", "proxy:99999", "http://proxy:8080/path"] {
            #expect(throws: BrookLinkError.self, "\(bad)") { try UpstreamProxy(parsing: bad) }
        }
    }

    @Test func loopbackDetection() {
        #expect(UpstreamProxy.isLoopback("127.0.0.1"))
        #expect(UpstreamProxy.isLoopback("127.8.9.10"))
        #expect(!UpstreamProxy.isLoopback("10.0.0.1"))
        #expect(!UpstreamProxy.isLoopback("proxy.corp"))
    }

    // MARK: - CONNECT wire format

    @Test func connectRequestCarriesHostnameAndBasicAuth() throws {
        let plain = String(decoding: UpstreamProxy(host: "p", port: 1).connectRequest(host: "vpn.example.com", port: 443), as: UTF8.self)
        #expect(plain.hasPrefix("CONNECT vpn.example.com:443 HTTP/1.1\r\nHost: vpn.example.com:443\r\n"))
        #expect(plain.hasSuffix("\r\n\r\n"))
        #expect(!plain.contains("Proxy-Authorization"))

        let authed = String(decoding: UpstreamProxy(host: "p", port: 1, username: "alice", password: "s3cret")
            .connectRequest(host: "1.2.3.4", port: 443), as: UTF8.self)
        #expect(authed.contains("Proxy-Authorization: Basic YWxpY2U6czNjcmV0\r\n"))

        let v6 = String(decoding: UpstreamProxy(host: "p", port: 1).connectRequest(host: "2001:db8::1", port: 443), as: UTF8.self)
        #expect(v6.hasPrefix("CONNECT [2001:db8::1]:443 HTTP/1.1"))
    }

    @Test func parsesConnectReplies() {
        #expect(ConnectResponse.parse(Data("HTTP/1.1 200 Connection".utf8)) == .incomplete)
        #expect(ConnectResponse.parse(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            == .status(code: 200, reason: "Connection established", leftover: Data()))
        // Tunnel bytes that arrive with the reply must not be lost.
        #expect(ConnectResponse.parse(Data("HTTP/1.0 200 OK\r\nVia: squid\r\n\r\n\u{16}\u{03}".utf8))
            == .status(code: 200, reason: "OK", leftover: Data([0x16, 0x03])))
        #expect(ConnectResponse.parse(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
            == .status(code: 407, reason: "Proxy Authentication Required", leftover: Data()))
        #expect(ConnectResponse.parse(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)) == .malformed)
        #expect(ConnectResponse.parse(Data(repeating: 0x41, count: ConnectResponse.maxHeader + 1)) == .malformed)
    }

    @Test func failuresExplainThemselvesAndOnlyTransientOnesRetry() {
        #expect(!ProxyFailure.authRequired.isRetryable)
        #expect(!ProxyFailure.refused(code: 403, reason: "Forbidden").isRetryable)
        #expect(ProxyFailure.refused(code: 502, reason: "Bad Gateway").isRetryable)
        #expect(ProxyFailure.timeout.isRetryable)
        #expect(ProxyFailure.refused(code: 403, reason: "").message(target: "x:9999").contains("443"))
        #expect(ProxyFailure.authRequired.message(target: "x").contains("407"))
    }

    // MARK: - Links

    @Test func relayedLinkAlwaysDialsTheRelayEvenWhenTheLinkHoldsAnIP() throws {
        // pinned(toIP:) leaves IP links untouched; the relay must still be used or brook bypasses the proxy.
        let ipLink = try BrookLink(parsing: "brook://server?password=hello&server=1.2.3.4%3A9999")
        let r = try BrookLink(parsing: ipLink.relayed(toLocalPort: 40000))
        #expect(r.dialHost == "127.0.0.1" && r.dialPort == 40000)
        #expect(r.queryValue("udpovertcp") == "true") // UDP can only go inside the CONNECT tunnel
        #expect(r.queryValue("password") == "hello")
        #expect(ipLink.dialHost == "1.2.3.4" && ipLink.dialPort == 9999) // the CONNECT target

        let wssIP = try BrookLink(parsing: "brook://wssserver?password=x&wssserver=wss%3A%2F%2F5.6.7.8%3A443%2Fws")
        #expect(try BrookLink(parsing: wssIP.relayed(toLocalPort: 40001)).addressHost == "127.0.0.1")
    }

    @Test func relayedWSSLinkKeepsDomainForTLS() throws {
        let link = try BrookLink(parsing: "brook://wssserver?password=x&wssserver=wss%3A%2F%2Fvpn.example.com%2Fws")
        let r = try BrookLink(parsing: link.relayed(toLocalPort: 40002))
        #expect(r.kind == .wssserver)
        #expect(r.host == "vpn.example.com" && r.port == 443)
        #expect(r.queryValue("wssserver") == "wss://vpn.example.com:443/ws")
        #expect(r.dialHost == "127.0.0.1" && r.dialPort == 40002)
        #expect(link.dialHost == "vpn.example.com" && link.dialPort == 443)
    }

    @Test func quicCannotUseAProxy() throws {
        #expect(!(try BrookLink(parsing: "brook://quicserver?password=x&quicserver=quic%3A%2F%2Fa.com%3A443")).canUseHTTPProxy)
        #expect(try BrookLink(parsing: "brook://wsserver?password=x&wsserver=ws%3A%2F%2Fa.com%3A80").canUseHTTPProxy)
    }

    // MARK: - Config

    @Test func configValidatesProxyAndWarnsAboutNon443() throws {
        var c = AppConfig()
        #expect(c.upstreamProxy.isEmpty)
        c.profiles = [
            Profile(name: "wss", link: "brook://wssserver?password=x&wssserver=wss%3A%2F%2Fa.com%3A443%2Fws"),
            Profile(name: "plain", link: "brook://server?password=x&server=1.2.3.4%3A9999"),
        ]
        #expect(c.validationErrors().isEmpty)
        #expect(c.warnings().isEmpty) // no proxy, no advice

        c.upstreamProxy = "proxy.corp:8080"
        #expect(c.validationErrors().isEmpty)
        #expect(c.warnings().count == 1)
        #expect(c.warnings().first?.contains("'plain'") == true)

        c.profiles.append(Profile(name: "q", link: "brook://quicserver?password=x&quicserver=quic%3A%2F%2Fa.com%3A443"))
        #expect(c.validationErrors().contains { $0.contains("QUIC") })

        c.upstreamProxy = "socks5://p:1"
        #expect(c.validationErrors().contains { $0.hasPrefix("HTTP proxy:") })
    }

    @Test func oldConfigWithoutProxyKeyStillLoads() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mode":"tun"}"#.utf8))
        #expect(c.upstreamProxy == "")
        var withProxy = AppConfig()
        withProxy.upstreamProxy = "http://u:p@proxy:8080"
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(withProxy))
        #expect(back.upstreamProxy == "http://u:p@proxy:8080")
    }

    // MARK: - Routing

    @Test func tunnelPlanRoutesProxyAndSkipsLoopback() throws {
        let gw = PhysicalGateway(router: "192.168.0.1", interface: "en1")
        let corp = try TunnelPlan(serverIPs: ["10.9.9.9"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1,
                                  allowNoServer: true)
        #expect(corp.helperArguments.contains("10.9.9.9"))

        // A local Px/cntlm must never get a host route via the gateway.
        let local = try TunnelPlan(serverIPs: ["127.0.0.1"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1,
                                   allowNoServer: true)
        #expect(!local.helperArguments.contains("--server"))
        #expect(throws: PlanError.noServerAddress) {
            try TunnelPlan(serverIPs: ["127.0.0.1"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
    }
}

// MARK: - Relay against a live fake proxy

/// A minimal CONNECT proxy on 127.0.0.1 that answers with `reply`, then echoes the tunnel.
private final class FakeProxy: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let reply: String
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(reply: String) throws {
        self.reply = reply
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 16)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: a.sin_port))
        Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                Thread { [self] in serve(c) }.start()
            }
        }.start()
    }

    func stop() { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }

    private func serve(_ c: Int32) {
        var head = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(c, &buf, buf.count)
            if n <= 0 { close(c); return }
            head.append(contentsOf: buf[0..<n])
        }
        lock.lock(); _requests.append(String(decoding: head, as: UTF8.self)); lock.unlock()
        _ = reply.withCString { write(c, $0, strlen($0)) }
        guard reply.contains(" 200 ") else { close(c); return }
        while true { // echo
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            _ = write(c, buf, n)
        }
        close(c)
    }
}

@Suite struct ConnectRelayTests {
    private func dial(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return fd
    }

    @Test func tunnelsBytesThroughProxyIncludingEarlyData() throws {
        // "early" arrives in the same packet as the 200 reply and must reach the client first.
        let proxy = try FakeProxy(reply: "HTTP/1.1 200 Connection established\r\n\r\nearly")
        defer { proxy.stop() }
        let up = UpstreamProxy(host: "127.0.0.1", port: proxy.port, username: "alice", password: "pw")
        let relay = try ConnectRelay(proxy: up, proxyIP: "127.0.0.1", targetHost: "vpn.example.com", targetPort: 443)
        defer { relay.stop() }

        let fd = dial(relay.port)
        defer { close(fd) }
        _ = "ping".withCString { write(fd, $0, 4) }
        var got = Data(), buf = [UInt8](repeating: 0, count: 64)
        while got.count < 9 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        #expect(String(decoding: got, as: UTF8.self) == "earlyping")
        let req = try #require(proxy.requests.first)
        #expect(req.hasPrefix("CONNECT vpn.example.com:443 HTTP/1.1"))
        #expect(req.contains("Proxy-Authorization: Basic "))
    }

    @Test func probeReportsProxyRefusals() throws {
        let deny = try FakeProxy(reply: "HTTP/1.1 403 Forbidden\r\n\r\n")
        defer { deny.stop() }
        #expect(ConnectRelay.probe(proxy: UpstreamProxy(host: "x", port: deny.port), proxyIP: "127.0.0.1", targetHost: "a", targetPort: 9999)
            == .refused(code: 403, reason: "Forbidden"))

        let auth = try FakeProxy(reply: "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
        defer { auth.stop() }
        #expect(ConnectRelay.probe(proxy: UpstreamProxy(host: "x", port: auth.port), proxyIP: "127.0.0.1", targetHost: "a", targetPort: 443)
            == .authRequired)

        let ok = try FakeProxy(reply: "HTTP/1.1 200 OK\r\n\r\n")
        defer { ok.stop() }
        #expect(ConnectRelay.probe(proxy: UpstreamProxy(host: "x", port: ok.port), proxyIP: "127.0.0.1", targetHost: "a", targetPort: 443) == nil)
    }

    @Test func probeReportsUnreachableProxy() throws {
        // Grab a free port, then close it so nothing listens there.
        let p = try FakeProxy(reply: "")
        let port = p.port
        p.stop()
        guard case .unreachable = ConnectRelay.probe(proxy: UpstreamProxy(host: "x", port: port), proxyIP: "127.0.0.1",
                                                     targetHost: "a", targetPort: 443) else {
            Issue.record("expected .unreachable")
            return
        }
    }

    @Test func stopClosesTheListener() throws {
        let proxy = try FakeProxy(reply: "HTTP/1.1 200 OK\r\n\r\n")
        defer { proxy.stop() }
        let relay = try ConnectRelay(proxy: UpstreamProxy(host: "x", port: proxy.port), proxyIP: "127.0.0.1", targetHost: "a", targetPort: 443)
        let port = relay.port
        relay.stop()
        relay.stop() // idempotent
        let fd = dial(port)
        defer { close(fd) }
        var b: UInt8 = 0
        #expect(read(fd, &b, 1) <= 0)
    }
}
