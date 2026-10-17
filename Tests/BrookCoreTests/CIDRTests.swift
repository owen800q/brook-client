import Testing
@testable import BrookCore

@Suite struct CIDRTests {
    @Test func normalizesHostBits() throws {
        #expect(try IPv4CIDR("192.168.1.7/16").description == "192.168.0.0/16")
        #expect(try IPv4CIDR("10.0.0.0/8").description == "10.0.0.0/8")
    }

    @Test func bareAddressIsSlash32() throws {
        #expect(try IPv4CIDR("192.168.0.128").description == "192.168.0.128/32")
        #expect(try IPv4CIDR("192.168.0.128").isHost)
    }

    @Test(arguments: [
        "", "abc", "300.1.1.1/8", "1.2.3.4/33", "1.2.3/8", "1.2.3.4/8;ls",
        "1.2.3.4/-1", " 1.2.3.4/8 x", "01.2.3.4/8", "1.2.3.4/", "::1/128",
    ])
    func rejectsInvalid(_ raw: String) {
        #expect(throws: CIDRError.self) { try IPv4CIDR(raw) }
    }

    @Test func toleratesSurroundingWhitespace() throws {
        #expect(try IPv4CIDR("  172.16.0.0/12 ").description == "172.16.0.0/12")
    }

    @Test func containment() throws {
        let lan = try IPv4CIDR("192.168.0.0/16")
        #expect(lan.contains("192.168.5.5"))
        #expect(!lan.contains("192.169.0.1"))
        #expect(!lan.contains("garbage"))
        #expect(try IPv4CIDR("0.0.0.0/0").contains("8.8.8.8"))
    }

    // Multicast and link-local are on-link: they must route via the interface, not the gateway.
    @Test func linkScoped() throws {
        #expect(try IPv4CIDR("224.0.0.0/4").isLinkScoped)
        #expect(try IPv4CIDR("239.255.255.250/32").isLinkScoped)
        #expect(try IPv4CIDR("169.254.0.0/16").isLinkScoped)
        #expect(try !IPv4CIDR("192.168.0.0/16").isLinkScoped)
        #expect(try !IPv4CIDR("10.0.0.0/8").isLinkScoped)
    }

    @Test func ipv4Validation() {
        #expect(IPv4.isValid("1.2.3.4"))
        #expect(IPv4.isValid("255.255.255.255"))
        #expect(!IPv4.isValid("256.1.1.1"))
        #expect(!IPv4.isValid("1.2.3"))
        #expect(!IPv4.isValid("1.2.3.4 "))
        #expect(!IPv4.isValid("example.com"))
    }
}
