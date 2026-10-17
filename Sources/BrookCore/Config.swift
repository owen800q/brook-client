import Foundation

public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var link: String

    public init(name: String, link: String) {
        self.name = name
        self.link = link
    }
}

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    /// Full-device TUN; needs the root helper.
    case tun
    /// macOS system HTTP/SOCKS proxy only.
    case proxy
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let defaultBypass = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4"]

    public var profiles: [Profile] = []
    public var selectedIndex: Int?
    public var mode: ConnectionMode = .tun
    public var bypassCIDRs: [String] = AppConfig.defaultBypass
    /// DNS servers set on the active network service while in TUN mode (queried through the tunnel). Empty = leave DNS alone.
    public var dns: [String] = ["8.8.8.8", "1.1.1.1"]
    public var socksPort = 1080
    public var httpPort = 1081
    public var connectOnLaunch = false
    /// TUN mode tunnels IPv4 only; reject global IPv6 so apps fall back to IPv4 instead of leaking.
    public var blockIPv6 = true
    /// Tunnel UDP (incl. DNS) inside TCP; needed when the server's firewall drops UDP.
    public var udpOverTCP = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? d.profiles
        selectedIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex)
        mode = try c.decodeIfPresent(ConnectionMode.self, forKey: .mode) ?? d.mode
        bypassCIDRs = try c.decodeIfPresent([String].self, forKey: .bypassCIDRs) ?? d.bypassCIDRs
        dns = try c.decodeIfPresent([String].self, forKey: .dns) ?? d.dns
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? d.socksPort
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort) ?? d.httpPort
        connectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? d.connectOnLaunch
        blockIPv6 = try c.decodeIfPresent(Bool.self, forKey: .blockIPv6) ?? d.blockIPv6
        udpOverTCP = try c.decodeIfPresent(Bool.self, forKey: .udpOverTCP) ?? d.udpOverTCP
    }

    public var selectedProfile: Profile? {
        guard let i = selectedIndex, profiles.indices.contains(i) else { return nil }
        return profiles[i]
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        for p in profiles {
            guard let link = try? BrookLink(parsing: p.link) else {
                errors.append("Server '\(p.name)': invalid brook link")
                continue
            }
            if link.kind == .socks5 { errors.append("Server '\(p.name)': socks5 links are not supported by brook connect") }
        }
        for c in bypassCIDRs where (try? IPv4CIDR(c)) == nil { errors.append("Bypass: '\(c)' is not an IPv4 address/CIDR") }
        for d in dns where !IPv4.isValid(d) { errors.append("DNS: '\(d)' is not an IPv4 address") }
        for (label, port) in [("SOCKS5", socksPort), ("HTTP", httpPort)] where !(1...65535).contains(port) {
            errors.append("\(label) port \(port) is out of range")
        }
        if socksPort == httpPort { errors.append("SOCKS5 and HTTP ports must differ") }
        return errors
    }
}

public struct ConfigStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: ConfigStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrookClient")
        return ConfigStore(url: dir.appendingPathComponent("config.json"))
    }

    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public func save(_ config: AppConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
