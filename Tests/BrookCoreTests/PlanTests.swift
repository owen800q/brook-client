import Testing
@testable import BrookCore

@Suite struct PlanTests {
    let gw = PhysicalGateway(router: "192.168.0.1", interface: "en1")

    @Test func tunPlanBuildsHelperArguments() throws {
        let plan = try TunnelPlan(
            serverIPs: ["5.6.7.8"],
            gateway: gw,
            bypass: ["192.168.0.0/16", "224.0.0.0/4", "10.1.2.3"],
            dns: ["8.8.8.8", "1.1.1.1"],
            socksPort: 1080,
            watchPID: 4242
        )
        #expect(plan.helperArguments == [
            "up",
            "--socks", "1080",
            "--gateway", "192.168.0.1",
            "--interface", "en1",
            "--server", "5.6.7.8",
            "--net", "192.168.0.0/16",
            "--link", "224.0.0.0/4",
            "--net", "10.1.2.3/32",
            "--dns", "8.8.8.8",
            "--dns", "1.1.1.1",
            "--watch", "4242",
        ])
    }

    @Test func tunPlanDeduplicatesAndOmitsEmptyDNS() throws {
        let plan = try TunnelPlan(
            serverIPs: ["5.6.7.8", "5.6.7.8"],
            gateway: gw,
            bypass: ["192.168.0.0/16", "192.168.1.0/16"],
            dns: [],
            socksPort: 1080,
            watchPID: 1
        )
        #expect(plan.helperArguments.filter { $0 == "--server" }.count == 1)
        #expect(plan.helperArguments.filter { $0 == "--net" }.count == 1)
        #expect(!plan.helperArguments.contains("--dns"))
    }

    @Test func tunPlanRejectsBadInput() {
        #expect(throws: PlanError.noServerAddress) {
            try TunnelPlan(serverIPs: [], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["example.com"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: ["nope"], dns: [], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: [], dns: ["8.8.8"], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: PhysicalGateway(router: "x", interface: "en1"),
                           bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: PhysicalGateway(router: "1.1.1.1", interface: "en1;id"),
                           bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
    }

    // The server must never be bypass-only: if its IP sits inside a bypass range that is
    // fine (it still goes to the gateway), but a bypass of 0.0.0.0/0 would defeat the tunnel.
    @Test func tunPlanRejectsDefaultRouteBypass() {
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: ["0.0.0.0/0"], dns: [], socksPort: 1080, watchPID: 1)
        }
    }

    @Test func proxyPlanBuildsHelperArguments() throws {
        let plan = try ProxyPlan(
            interface: "en1",
            httpPort: 1081,
            socksPort: 1080,
            bypass: ["192.168.0.0/16", "10.0.0.0/8"],
            watchPID: 7
        )
        #expect(plan.helperArguments == [
            "proxy-on",
            "--interface", "en1",
            "--http", "1081",
            "--socks", "1080",
            "--bypass", "192.168.0.0/16",
            "--bypass", "10.0.0.0/8",
            "--watch", "7",
        ])
    }

    @Test func proxyBypassDomainsAlwaysIncludeLocalNames() throws {
        let plan = try ProxyPlan(interface: "en1", httpPort: 1081, socksPort: 1080, bypass: ["192.168.0.0/16"], watchPID: 7)
        #expect(plan.systemBypassList == ["localhost", "127.0.0.1", "*.local", "192.168.0.0/16"])
    }
}
