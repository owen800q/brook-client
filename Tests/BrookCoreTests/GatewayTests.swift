import Foundation
import Testing
@testable import BrookCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct GatewayTests {
    // Captured live while the official Brook app was connected: the only physical
    // default route is the interface-scoped one on en1.
    @Test func findsPhysicalGatewayWhileAnotherVPNIsUp() throws {
        let gw = try #require(PhysicalGateway.parse(netstat: fixture("netstat_vpn_on")))
        #expect(gw == PhysicalGateway(router: "192.168.0.1", interface: "en1"))
    }

    @Test func prefersUnscopedPrimaryDefault() throws {
        let gw = try #require(PhysicalGateway.parse(netstat: fixture("netstat_plain")))
        #expect(gw == PhysicalGateway(router: "10.0.1.254", interface: "en0"))
    }

    @Test func nilWhenOnlyTunnelDefaults() throws {
        #expect(PhysicalGateway.parse(netstat: try fixture("netstat_no_gateway")) == nil)
    }

    @Test func detectsForeignVPNHoldingDefaultRoute() throws {
        #expect(PhysicalGateway.foreignTunnelOwnsDefault(netstat: try fixture("netstat_vpn_on"), ownTunnel: nil))
        #expect(!PhysicalGateway.foreignTunnelOwnsDefault(netstat: try fixture("netstat_plain"), ownTunnel: nil))
        #expect(!PhysicalGateway.foreignTunnelOwnsDefault(netstat: try fixture("netstat_vpn_on"), ownTunnel: "utun4"))
    }
}
