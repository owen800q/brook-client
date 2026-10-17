import Foundation

public enum BrookLinkError: Error, Equatable {
    case invalid(String)
}

/// A parsed `brook://kind?kind=...&password=...` link, as produced by `brook link`.
public struct BrookLink: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case server, wsserver, wssserver, quicserver, socks5

        /// URL scheme of the kind's server parameter; nil for plain `host:port`.
        var scheme: String? {
            switch self {
            case .server: nil
            case .wsserver: "ws"
            case .wssserver: "wss"
            case .quicserver: "quic"
            case .socks5: "socks5"
            }
        }

        var defaultPort: Int? {
            switch self {
            case .server: nil
            case .wsserver: 80
            case .wssserver, .quicserver: 443
            case .socks5: 1080
            }
        }
    }

    public let raw: String
    public let kind: Kind
    /// Host in the server parameter (domain or IP). For ws/wss this is also the TLS/Host name.
    public let host: String
    public let port: Int
    /// Host from the `address` parameter, which brook dials instead of resolving `host`.
    public let addressHost: String?
    private let addressPort: Int?
    /// Server URL with the implicit default port made explicit, when it was missing (brook requires it).
    private let serverValueWithPort: String?
    private let query: [(key: String, value: String)]

    public static func == (a: BrookLink, b: BrookLink) -> Bool { a.raw == b.raw }

    public init(parsing input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "brook://"
        guard raw.hasPrefix(prefix), let q = raw.firstIndex(of: "?") else { throw BrookLinkError.invalid("not a brook:// link") }
        let kindName = String(raw[raw.index(raw.startIndex, offsetBy: prefix.count)..<q])
        guard let kind = Kind(rawValue: kindName) else { throw BrookLinkError.invalid("unsupported kind '\(kindName)'") }
        let query = Self.parseQuery(String(raw[raw.index(after: q)...]))
        guard let serverValue = query.first(where: { $0.key == kindName })?.value, !serverValue.isEmpty else {
            throw BrookLinkError.invalid("missing \(kindName) parameter")
        }

        let endpoint: (host: String, port: Int)?
        if let scheme = kind.scheme {
            endpoint = Self.parseURLEndpoint(serverValue, scheme: scheme, defaultPort: kind.defaultPort)
        } else {
            endpoint = Self.parseHostPort(serverValue)
        }
        guard let endpoint else { throw BrookLinkError.invalid("bad \(kindName) address '\(serverValue)'") }

        var addressHost: String?, addressPort: Int?
        if let address = query.first(where: { $0.key == "address" })?.value, !address.isEmpty {
            guard let a = Self.parseHostPort(address) else { throw BrookLinkError.invalid("bad address '\(address)'") }
            addressHost = a.host
            addressPort = a.port
        }

        var serverValueWithPort: String?
        if kind.scheme != nil, var c = URLComponents(string: serverValue), c.port == nil {
            c.port = endpoint.port
            serverValueWithPort = c.string
        }

        self.raw = raw
        self.kind = kind
        self.host = endpoint.host
        self.port = endpoint.port
        self.addressHost = addressHost
        self.addressPort = addressPort
        self.serverValueWithPort = serverValueWithPort
        self.query = query
    }

    public var name: String? { queryValue("name") }

    /// What brook connects to: `address` if given, otherwise the server host.
    public var dialHost: String { addressHost ?? host }
    public var dialPort: Int { addressPort ?? port }
    public var dialHostIsIPv4: Bool { IPv4.isValid(dialHost) }

    public func queryValue(_ key: String) -> String? {
        query.first { $0.key == key }?.value
    }

    /// Returns a link that makes brook dial `ip` exactly, so the server connection always
    /// matches the host route we install outside the tunnel. Also makes implicit URL ports
    /// explicit, since `brook connect` rejects URLs without one.
    public func pinned(toIP ip: String) -> String {
        pinned(toIP: ip, udpOverTCP: false)
    }

    /// `udpOverTCP` carries UDP inside the TCP/QUIC stream (brook's udpovertcp / udpoverstream),
    /// for servers whose firewall drops UDP. ws/wss already do this inherently.
    public func pinned(toIP ip: String, udpOverTCP: Bool) -> String {
        var items = query
        var changed = false
        func set(_ key: String, _ value: String) {
            changed = true
            if let i = items.firstIndex(where: { $0.key == key }) { items[i].value = value } else { items.append((key, value)) }
        }
        switch kind {
        case .server:
            if !dialHostIsIPv4 { set("server", "\(ip):\(port)") }
        case .socks5:
            break // not usable with `brook connect`; rejected by config validation
        case .wsserver, .wssserver, .quicserver:
            if let v = serverValueWithPort { set(kind.rawValue, v) }
            // Keep the domain in the URL for TLS SNI / Host header; pin the dial address.
            if !dialHostIsIPv4 { set("address", "\(ip):\(dialPort)") }
        }
        if udpOverTCP {
            let flag: String? = switch kind {
            case .server: "udpovertcp"
            case .quicserver: "udpoverstream"
            default: nil
            }
            if let flag, items.first(where: { $0.key == flag })?.value != "true" { set(flag, "true") }
        }
        return changed ? "brook://\(kind.rawValue)?" + Self.encodeQuery(items) : raw
    }

    // MARK: - Parsing helpers

    private static func parseQuery(_ s: String) -> [(key: String, value: String)] {
        s.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = decode(kv[0]) else { return nil }
            return (k, kv.count > 1 ? decode(kv[1]) ?? "" : "")
        }
    }

    private static func decode(_ s: Substring) -> String? {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    /// Matches Go's url.Values.Encode (sorted keys, QueryEscape) like `brook link` emits.
    private static func encodeQuery(_ items: [(key: String, value: String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~ ")
        func esc(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
        }
        return items.sorted { $0.key < $1.key }.map { "\(esc($0.key))=\(esc($0.value))" }.joined(separator: "&")
    }

    /// `host:port` or `[v6]:port`.
    static func parseHostPort(_ s: String) -> (host: String, port: Int)? {
        let host: Substring, portPart: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]"), s[s.index(after: close)...].hasPrefix(":") else { return nil }
            host = s[s.index(after: s.startIndex)..<close]
            portPart = s[s.index(close, offsetBy: 2)...]
        } else {
            guard let colon = s.lastIndex(of: ":") else { return nil }
            host = s[..<colon]
            portPart = s[s.index(after: colon)...]
            if host.contains(":") { return nil }
        }
        guard !host.isEmpty, let port = parsePort(portPart) else { return nil }
        return (String(host), port)
    }

    private static func parseURLEndpoint(_ s: String, scheme: String, defaultPort: Int?) -> (host: String, port: Int)? {
        guard let c = URLComponents(string: s), c.scheme == scheme,
              var host = c.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard let port = c.port ?? defaultPort, (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func parsePort(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy(\.isASCIIDigit), let p = Int(s), (1...65535).contains(p) else { return nil }
        return p
    }
}
