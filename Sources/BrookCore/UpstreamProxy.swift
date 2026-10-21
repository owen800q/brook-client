import Foundation

/// A corporate HTTP proxy that brook's server connection must go through (HTTP CONNECT).
///
/// Accepted forms: `host:port`, `http://host:port`, `http://user:pass@host:port`.
/// Only Basic auth is supported; for NTLM/Kerberos run a local helper such as Px or cntlm
/// and point this at it (`127.0.0.1:3128`).
public struct UpstreamProxy: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?

    public init(host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// Returns nil for an empty string; throws for a malformed one.
    public init?(parsing input: String) throws {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let withScheme = s.contains("://") ? s : "http://" + s
        guard let c = URLComponents(string: withScheme), let scheme = c.scheme?.lowercased() else {
            throw BrookLinkError.invalid("bad proxy '\(s)'")
        }
        guard scheme == "http" else {
            throw BrookLinkError.invalid("proxy must be an http:// proxy (HTTP CONNECT), not \(scheme)://")
        }
        guard var host = c.host, !host.isEmpty, let port = c.port, (1...65535).contains(port) else {
            throw BrookLinkError.invalid("proxy needs host:port, e.g. proxy.corp.example:8080")
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard c.path.isEmpty || c.path == "/" else { throw BrookLinkError.invalid("proxy must not have a path") }
        self.host = host
        self.port = port
        username = c.user.flatMap { $0.removingPercentEncoding ?? $0 }
        password = c.password.flatMap { $0.removingPercentEncoding ?? $0 }
    }

    public var hostIsIPv4: Bool { IPv4.isValid(host) }

    /// A proxy on this Mac (Px, cntlm, …). It must never get a host route via the gateway.
    public static func isLoopback(_ ip: String) -> Bool {
        guard let v = IPv4.parse(ip) else { return false }
        return v >> 24 == 127
    }

    /// The CONNECT request that opens a raw TCP tunnel to `host:port`.
    public func connectRequest(host target: String, port targetPort: Int) -> Data {
        let authority = target.contains(":") ? "[\(target)]:\(targetPort)" : "\(target):\(targetPort)"
        var lines = ["CONNECT \(authority) HTTP/1.1", "Host: \(authority)"]
        if let username = username {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        lines.append("Proxy-Connection: Keep-Alive")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// Result of reading a proxy's reply to CONNECT.
public enum ConnectResponse: Equatable, Sendable {
    /// Header not complete yet; read more.
    case incomplete
    /// Header parsed. `leftover` is any tunnel data that arrived after the blank line.
    case status(code: Int, reason: String, leftover: Data)
    case malformed

    /// Largest header we accept before giving up.
    public static let maxHeader = 16 * 1024

    public static func parse(_ buffer: Data) -> ConnectResponse {
        let end = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: end) else {
            return buffer.count > maxHeader ? .malformed : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]), (100...599).contains(code) else {
            return .malformed
        }
        let reason = parts.count > 2 ? String(parts[2]) : ""
        return .status(code: code, reason: reason, leftover: Data(buffer[r.upperBound...]))
    }
}

/// Why a CONNECT through the upstream proxy failed, phrased for the user.
public enum ProxyFailure: Error, Equatable, Sendable {
    case unreachable(String)
    case timeout
    case authRequired
    case refused(code: Int, reason: String)
    case malformed

    /// 407/403 mean the proxy deliberately said no; retrying won't help.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .timeout, .malformed: return true
        case .authRequired: return false
        case let .refused(code, _): return code >= 500
        }
    }

    public func message(target: String) -> String {
        switch self {
        case let .unreachable(why): return "Cannot reach the HTTP proxy: \(why)"
        case .timeout: return "The HTTP proxy did not answer in time"
        case .authRequired:
            return "The HTTP proxy needs a login (407). Add user:password to the proxy setting, or use Px/cntlm for NTLM/Kerberos."
        case let .refused(403, _):
            return "The HTTP proxy blocked \(target) (403). Corporate proxies often allow CONNECT only to port 443 — use a wssserver on :443."
        case let .refused(code, reason): return "The HTTP proxy refused \(target): \(code) \(reason)"
        case .malformed: return "The HTTP proxy sent an unexpected reply (is it really an HTTP proxy?)"
        }
    }
}
