import Darwin
import Foundation

/// Thin, blocking wrappers around the OS. Call off the main thread.
enum System {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ path: String, _ args: [String]) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Output(status: -1, stdout: "", stderr: "\(error)") }
        // Read both pipes before waiting so a chatty child can't deadlock on a full pipe.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Output(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    static func routingTable() -> String {
        run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).stdout
    }

    /// IPv4 addresses for a host name (or the literal itself).
    static func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var ips: [String] = []
        var p = res
        while let ai = p {
            if let sa = ai.pointee.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if !ips.contains(ip) { ips.append(ip) }
            }
            p = ai.pointee.ai_next
        }
        return ips
    }

    static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The manual HTTPS (else HTTP) proxy from macOS network settings, skipping our own
    /// 127.0.0.1 listeners (which System-proxy mode installs there).
    static func systemHTTPProxy(ignoringLocalPorts own: [Int]) -> (host: String, port: Int)? {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        for (enable, host, port) in [("HTTPSEnable", "HTTPSProxy", "HTTPSPort"), ("HTTPEnable", "HTTPProxy", "HTTPPort")] {
            guard (dict[enable] as? NSNumber)?.boolValue == true, let h = dict[host] as? String, !h.isEmpty,
                  let p = (dict[port] as? NSNumber)?.intValue, (1...65535).contains(p) else { continue }
            if h == "127.0.0.1" || h == "localhost", own.contains(p) { continue }
            return (h, p)
        }
        return nil
    }

    static func interfaceExists(_ name: String) -> Bool {
        if_nametoindex(name) != 0
    }

    static func processAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Paths of bundled and installed components.
enum Paths {
    static let installedHelper = "/Library/PrivilegedHelperTools/com.brookclient.helper"
    static let installedTun2socks = "/Library/PrivilegedHelperTools/com.brookclient.tun2socks"

    static var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }

    /// Bundled brook, falling back to Homebrew's when running unbundled (swift run).
    static var brook: String? {
        let candidates = [resources.appendingPathComponent("brook").path, "/opt/homebrew/bin/brook", "/usr/local/bin/brook"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var logDir: URL {
        let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BrookClient")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var brookLog: URL { logDir.appendingPathComponent("brook.log") }
}
