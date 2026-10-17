/// The real (non-tunnel) router and interface, parsed from `netstat -rn -f inet`.
public struct PhysicalGateway: Equatable, Sendable {
    public let router: String
    public let interface: String

    public init(router: String, interface: String) {
        self.router = router
        self.interface = interface
    }

    private struct Row {
        let destination, gateway, flags, netif: String
        /// RTF_IFSCOPE: only used by sockets bound to that interface.
        var isScoped: Bool { flags.contains("I") }
        var isTunnel: Bool { ["utun", "ipsec", "ppp", "tun", "gif"].contains { netif.hasPrefix($0) } }
    }

    private static func rows(_ netstat: String) -> [Row] {
        netstat.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 4 else { return nil }
            return Row(destination: f[0], gateway: f[1], flags: f[2], netif: f[3])
        }
    }

    /// Picks a default route via a real router on a non-tunnel interface, preferring the
    /// unscoped (primary) one. While another VPN is up the physical default is often scoped.
    public static func parse(netstat: String) -> PhysicalGateway? {
        let candidates = rows(netstat).filter {
            $0.destination == "default" && $0.flags.contains("G") && !$0.isTunnel && $0.netif != "lo0" && IPv4.isValid($0.gateway)
        }
        guard let best = candidates.first(where: { !$0.isScoped }) ?? candidates.first else { return nil }
        return PhysicalGateway(router: best.gateway, interface: best.netif)
    }

    /// True when some other tunnel (e.g. the official Brook app) holds the unscoped default
    /// or 0/1 route; running alongside it would fight over routing.
    public static func foreignTunnelOwnsDefault(netstat: String, ownTunnel: String?) -> Bool {
        rows(netstat).contains {
            ["default", "0/1", "0.0.0.0/1"].contains($0.destination) && $0.isTunnel && !$0.isScoped && $0.netif != ownTunnel
        }
    }
}
