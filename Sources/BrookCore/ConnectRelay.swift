import Darwin
import Foundation

/// A loopback listener that tunnels every accepted connection to one fixed target through an
/// HTTP proxy (CONNECT), so brook — which cannot use a proxy itself — reaches its server.
///
///   brook connect → 127.0.0.1:<port> → HTTP proxy → CONNECT target:port → brook server
public final class ConnectRelay: @unchecked Sendable {
    public let port: Int
    private let proxy: UpstreamProxy
    private let proxyIP: String
    private let targetHost: String
    private let targetPort: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var live = Set<Int32>()
    private let log: @Sendable (String) -> Void

    static let handshakeTimeout: TimeInterval = 15

    /// `proxyIP` is the already-resolved proxy address, so the relay dials exactly the IP that is
    /// routed outside the tunnel.
    public init(proxy: UpstreamProxy, proxyIP: String, targetHost: String, targetPort: Int,
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.proxy = proxy
        self.proxyIP = proxyIP
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.log = log
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyFailure.unreachable("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.sockaddr4("127.0.0.1", 0)!
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw ProxyFailure.unreachable("cannot open local relay: \(why)")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = Int(UInt16(bigEndian: got.sin_port))
        Self.spawn { [self] in acceptLoop() }
    }

    deinit { stop() }

    /// Closes the listener and every open tunnel. Idempotent.
    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let fds = live
        live.removeAll()
        lock.unlock()
        // shutdown() wakes threads blocked in accept/read on these descriptors.
        Darwin.shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        for fd in fds { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    /// One CONNECT handshake to the target, then close. Use before declaring "connected" so a
    /// refusing proxy surfaces as a clear error instead of a silent dead tunnel.
    public static func probe(proxy: UpstreamProxy, proxyIP: String, targetHost: String, targetPort: Int) -> ProxyFailure? {
        switch openTunnel(proxy: proxy, proxyIP: proxyIP, targetHost: targetHost, targetPort: targetPort) {
        case let .success((fd, _)): close(fd); return nil
        case let .failure(f): return f
        }
    }

    // MARK: - Internals

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return // listener closed by stop()
            }
            guard track(client) else { close(client); return }
            Self.spawn { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        Self.noSigPipe(client)
        switch Self.openTunnel(proxy: proxy, proxyIP: proxyIP, targetHost: targetHost, targetPort: targetPort) {
        case let .failure(f):
            log("relay: \(f.message(target: "\(targetHost):\(targetPort)"))")
            untrack(client)
            close(client)
        case let .success((upstream, leftover)):
            guard track(upstream) else { close(upstream); untrack(client); close(client); return }
            if !leftover.isEmpty, !Self.writeAll(client, leftover) {
                Darwin.shutdown(upstream, SHUT_RDWR)
            }
            // Pump each direction on its own thread; half-close so brook sees a clean EOF.
            let done = DispatchGroup()
            done.enter()
            Self.spawn { Self.pump(from: upstream, to: client); done.leave() }
            Self.pump(from: client, to: upstream)
            done.wait()
            untrack(client); untrack(upstream)
            close(client); close(upstream)
        }
    }

    private func track(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        live.insert(fd)
        return true
    }

    private func untrack(_ fd: Int32) {
        lock.lock(); live.remove(fd); lock.unlock()
    }

    private static func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            if !buf.withUnsafeBytes({ writeAll(dst, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) { break }
        }
        Darwin.shutdown(dst, SHUT_WR)
        Darwin.shutdown(src, SHUT_RD)
    }

    /// Connects to the proxy, sends CONNECT and reads the reply. On success returns the socket
    /// (now a raw tunnel) and any tunnel bytes that came with the reply.
    static func openTunnel(proxy: UpstreamProxy, proxyIP: String, targetHost: String,
                           targetPort: Int) -> Result<(Int32, Data), ProxyFailure> {
        guard var addr = sockaddr4(proxyIP, proxy.port) else { return .failure(.unreachable("bad proxy address \(proxyIP)")) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.unreachable(String(cString: strerror(errno)))) }
        noSigPipe(fd)
        setTimeout(fd, handshakeTimeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            return .failure(e == ETIMEDOUT || e == EAGAIN ? .timeout
                : .unreachable("\(proxy.host):\(proxy.port) — \(String(cString: strerror(e)))"))
        }
        guard writeAll(fd, proxy.connectRequest(host: targetHost, port: targetPort)) else {
            close(fd)
            return .failure(.unreachable("connection closed while sending CONNECT"))
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n < 0 {
                let e = errno
                close(fd)
                return .failure(e == EAGAIN || e == EWOULDBLOCK ? .timeout : .unreachable(String(cString: strerror(e))))
            }
            if n == 0 { close(fd); return .failure(buffer.isEmpty ? .unreachable("proxy closed the connection") : .malformed) }
            buffer.append(contentsOf: chunk[0..<n])
            switch ConnectResponse.parse(buffer) {
            case .incomplete: continue
            case .malformed: close(fd); return .failure(.malformed)
            case let .status(code, reason, leftover):
                if (200...299).contains(code) {
                    setTimeout(fd, 0) // tunnel is idle-tolerant; brook has its own keepalives/timeouts
                    return .success((fd, leftover))
                }
                close(fd)
                return .failure(code == 407 ? .authRequired : .refused(code: code, reason: reason))
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { writeAll(fd, $0) }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func sockaddr4(_ ip: String, _ port: Int) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        return a
    }

    /// Plain threads, not GCD: every tunnel blocks in read(), which would starve the GCD pool.
    private static func spawn(_ body: @escaping @Sendable () -> Void) {
        let t = Thread(block: body)
        t.stackSize = 256 * 1024
        t.start()
    }
}
