import Foundation
import Testing
@testable import BrookCore

/// Defects found by independent review of the first implementation.
@Suite struct LinkRegressionTests {
    // brook dials the address param's port, not the URL's.
    @Test func pinningKeepsAddressPort() throws {
        let link = try BrookLink(parsing: "brook://wssserver?address=cdn.example.net%3A2053&password=x&wssserver=wss%3A%2F%2Fexample.com%3A8443%2Fws")
        let pinned = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9"))
        #expect(pinned.queryValue("address") == "9.9.9.9:2053")
        #expect(link.dialPort == 2053)
    }

    // `brook connect` rejects URLs without an explicit port ("missing port in address").
    @Test func pinningAddsImplicitPortToURL() throws {
        let link = try BrookLink(parsing: "brook://wssserver?password=x&wssserver=wss%3A%2F%2Fexample.com%2Fws")
        let pinned = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9"))
        #expect(pinned.queryValue("wssserver") == "wss://example.com:443/ws")
        #expect(pinned.queryValue("address") == "9.9.9.9:443")
    }

    @Test func implicitPortAddedEvenWhenHostIsAlreadyIP() throws {
        let link = try BrookLink(parsing: "brook://wsserver?password=x&wsserver=ws%3A%2F%2F1.2.3.4%2Fws")
        let pinned = try BrookLink(parsing: link.pinned(toIP: "1.2.3.4"))
        #expect(pinned.queryValue("wsserver") == "ws://1.2.3.4:80/ws")
    }

    // brook connect can't use a socks5 link ("create socks5 from a socks5").
    @Test func socks5ProfilesAreReportedUnsupported() {
        var c = AppConfig()
        c.profiles = [Profile(name: "s5", link: "brook://socks5?password=p&socks5=socks5%3A%2F%2F1.2.3.4%3A1080&username=u")]
        #expect(c.validationErrors().contains { $0.contains("socks5") })
    }
}

@Suite struct PlanRegressionTests {
    let gw = PhysicalGateway(router: "192.168.0.1", interface: "en1")

    @Test func rejectsOutOfRangePortAndPID() {
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: [], dns: [], socksPort: 0, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: -5)
        }
        #expect(throws: PlanError.self) {
            try ProxyPlan(interface: "en1", httpPort: 70000, socksPort: 1080, bypass: [], watchPID: 1)
        }
    }

    @Test func rejectsOverlyBroadBypass() {
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: ["0.0.0.0/1", "128.0.0.0/1"], dns: [], socksPort: 1080, watchPID: 1)
        }
        // 224.0.0.0/4 (multicast) is the broadest legitimate default.
        #expect(throws: Never.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: ["224.0.0.0/4"], dns: [], socksPort: 1080, watchPID: 1)
        }
    }

    @Test func rejectsUnspecifiedAddresses() {
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["0.0.0.0"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
        #expect(throws: PlanError.self) {
            try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: PhysicalGateway(router: "0.0.0.0", interface: "en1"),
                           bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        }
    }

    // Global IPv6 would otherwise leave the machine outside the IPv4-only tunnel.
    @Test func blockIPv6AddsHelperFlag() throws {
        let plan = try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1, blockIPv6: true)
        #expect(plan.helperArguments.suffix(4) == ["--ipv6", "block", "--watch", "1"])
        let off = try TunnelPlan(serverIPs: ["1.2.3.4"], gateway: gw, bypass: [], dns: [], socksPort: 1080, watchPID: 1)
        #expect(!off.helperArguments.contains("--ipv6"))
    }

    @Test func configDefaultsToBlockingIPv6() {
        #expect(AppConfig().blockIPv6)
    }
}
