public enum PlanError: Error, Equatable {
    case noServerAddress
    case invalidServerAddress(String)
    case invalidGateway(String)
    case invalidInterface(String)
    case invalidCIDR(String)
    case invalidDNS(String)
    case bypassTooBroad(String)
    case invalidPort(Int)
    case invalidPID(Int32)
}

/// A unicast IPv4 address usable as a route target (not 0.0.0.0).
func isRoutableIPv4(_ s: String) -> Bool {
    guard let v = IPv4.parse(s) else { return false }
    return v != 0
}

func validatePort(_ p: Int) throws {
    guard (1...65535).contains(p) else { throw PlanError.invalidPort(p) }
}

func validatePID(_ pid: Int32) throws {
    guard pid > 0 else { throw PlanError.invalidPID(pid) }
}

/// Interface names as accepted by the root helper.
func isValidInterfaceName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 15 && s.allSatisfy { $0.isASCIIDigit || ("a"..."z").contains($0) }
}

func parseBypass(_ raw: [String]) throws -> [IPv4CIDR] {
    var seen = Set<IPv4CIDR>(), out: [IPv4CIDR] = []
    for r in raw {
        guard let c = try? IPv4CIDR(r) else { throw PlanError.invalidCIDR(r) }
        // 224.0.0.0/4 (multicast) is the broadest legitimate range; anything wider defeats the tunnel.
        if c.prefix < 4 { throw PlanError.bypassTooBroad(r) }
        if seen.insert(c).inserted { out.append(c) }
    }
    return out
}

/// Full-device mode: everything into the TUN except the brook server and bypass ranges,
/// which go straight to the physical gateway (so LAN devices like a TV stay reachable).
public struct TunnelPlan: Equatable {
    public let helperArguments: [String]

    public init(serverIPs: [String], gateway: PhysicalGateway, bypass: [String], dns: [String], socksPort: Int, watchPID: Int32,
                blockIPv6: Bool = false) throws {
        var servers: [String] = []
        for ip in serverIPs where !servers.contains(ip) {
            guard isRoutableIPv4(ip) else { throw PlanError.invalidServerAddress(ip) }
            servers.append(ip)
        }
        guard !servers.isEmpty else { throw PlanError.noServerAddress }
        guard isRoutableIPv4(gateway.router) else { throw PlanError.invalidGateway(gateway.router) }
        try validatePort(socksPort)
        try validatePID(watchPID)
        guard isValidInterfaceName(gateway.interface) else { throw PlanError.invalidInterface(gateway.interface) }
        for d in dns where !IPv4.isValid(d) { throw PlanError.invalidDNS(d) }

        var args = ["up", "--socks", String(socksPort), "--gateway", gateway.router, "--interface", gateway.interface]
        for s in servers { args += ["--server", s] }
        for c in try parseBypass(bypass) { args += [c.isLinkScoped ? "--link" : "--net", c.description] }
        for d in dns { args += ["--dns", d] }
        if blockIPv6 { args += ["--ipv6", "block"] }
        args += ["--watch", String(watchPID)]
        helperArguments = args
    }
}

/// System-proxy mode: only proxy-aware apps use brook; CLI tools like sdb never do.
public struct ProxyPlan: Equatable {
    public let helperArguments: [String]
    public let systemBypassList: [String]

    public init(interface: String, httpPort: Int, socksPort: Int, bypass: [String], watchPID: Int32) throws {
        guard isValidInterfaceName(interface) else { throw PlanError.invalidInterface(interface) }
        try validatePort(httpPort)
        try validatePort(socksPort)
        try validatePID(watchPID)
        let cidrs = try parseBypass(bypass).map(\.description)
        var args = ["proxy-on", "--interface", interface, "--http", String(httpPort), "--socks", String(socksPort)]
        for c in cidrs { args += ["--bypass", c] }
        args += ["--watch", String(watchPID)]
        helperArguments = args
        // The helper always prepends these local names.
        systemBypassList = ["localhost", "127.0.0.1", "*.local"] + cidrs
    }
}
