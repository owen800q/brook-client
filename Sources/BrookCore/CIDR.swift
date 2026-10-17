import Foundation

public enum CIDRError: Error, Equatable {
    case invalid(String)
}

public enum IPv4 {
    /// Strict dotted-quad: four decimal octets 0...255, no leading zeros, no whitespace.
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCIIDigit),
                  !(part.count > 1 && part.first == "0"),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        return value
    }

    public static func isValid(_ s: String) -> Bool { parse(s) != nil }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xff).\(v >> 16 & 0xff).\(v >> 8 & 0xff).\(v & 0xff)"
    }
}

public struct IPv4CIDR: Hashable, CustomStringConvertible, Sendable {
    public let network: UInt32
    public let prefix: Int

    public init(_ raw: String) throws {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = s.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2, let addr = IPv4.parse(String(pieces[0])) else {
            throw CIDRError.invalid(raw)
        }
        var prefix = 32
        if pieces.count == 2 {
            let p = pieces[1]
            guard !p.isEmpty, p.count <= 2, p.allSatisfy(\.isASCIIDigit), let n = Int(p), n <= 32 else {
                throw CIDRError.invalid(raw)
            }
            prefix = n
        }
        self.prefix = prefix
        self.network = addr & Self.mask(prefix)
    }

    private static func mask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    }

    public var description: String { "\(IPv4.format(network))/\(prefix)" }
    public var isHost: Bool { prefix == 32 }

    public func contains(_ ip: String) -> Bool {
        guard let v = IPv4.parse(ip) else { return false }
        return v & Self.mask(prefix) == network
    }

    func contains(_ other: IPv4CIDR) -> Bool {
        other.prefix >= prefix && other.network & Self.mask(prefix) == network
    }

    /// Multicast (224/4) and link-local (169.254/16) are on-link: route via the interface, not the router.
    public var isLinkScoped: Bool {
        Self.linkScopedRanges.contains { $0.contains(self) }
    }

    private static let linkScopedRanges = [
        try! IPv4CIDR("224.0.0.0/4"),
        try! IPv4CIDR("169.254.0.0/16"),
    ]
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
