import Testing
@testable import BrookCore

@Suite struct BrookLinkTests {
    @Test func parsesPlainServerLink() throws {
        let link = try BrookLink(parsing: "brook://server?password=hello&server=1.2.3.4%3A9999")
        #expect(link.kind == .server)
        #expect(link.host == "1.2.3.4")
        #expect(link.port == 9999)
        #expect(link.dialHost == "1.2.3.4")
        #expect(link.name == nil)
    }

    @Test func parsesWssLinkWithAddressOverride() throws {
        let link = try BrookLink(parsing: "brook://wssserver?address=5.6.7.8%3A443&password=hello&wssserver=wss%3A%2F%2Fexample.com%3A443%2Fws")
        #expect(link.kind == .wssserver)
        #expect(link.host == "example.com")
        #expect(link.port == 443)
        // The address parameter is what brook actually dials.
        #expect(link.dialHost == "5.6.7.8")
    }

    @Test func parsesWsLinkWithName() throws {
        let link = try BrookLink(parsing: "brook://wsserver?name=Home+HK&password=x&wsserver=ws%3A%2F%2Fexample.com%3A80%2Fws")
        #expect(link.kind == .wsserver)
        #expect(link.name == "Home HK")
        #expect(link.host == "example.com")
        #expect(link.port == 80)
    }

    @Test func wssDefaultsTo443WhenPortMissing() throws {
        let link = try BrookLink(parsing: "brook://wssserver?password=x&wssserver=wss%3A%2F%2Fexample.com%2Fws")
        #expect(link.port == 443)
    }

    @Test func parsesQuicAndSocks5() throws {
        let quic = try BrookLink(parsing: "brook://quicserver?password=x&quicserver=quic%3A%2F%2Fexample.com%3A443")
        #expect(quic.kind == .quicserver)
        #expect(quic.host == "example.com")
        let socks = try BrookLink(parsing: "brook://socks5?password=p&socks5=socks5%3A%2F%2F1.2.3.4%3A1080&username=u")
        #expect(socks.kind == .socks5)
        #expect(socks.host == "1.2.3.4")
        #expect(socks.port == 1080)
    }

    @Test func parsesBracketedIPv6Server() throws {
        let link = try BrookLink(parsing: "brook://server?password=x&server=%5B2001%3Adb8%3A%3A1%5D%3A9999")
        #expect(link.host == "2001:db8::1")
        #expect(link.port == 9999)
    }

    @Test(arguments: [
        "",
        "http://server?server=1.2.3.4%3A1",
        "brook://server?password=x",                       // missing server param
        "brook://unknown?unknown=1.2.3.4%3A1",
        "brook://server?server=1.2.3.4",                   // missing port
        "brook://server?server=1.2.3.4%3A99999",           // bad port
        "brook://wssserver?wssserver=notaurl",
    ])
    func rejectsInvalidLinks(_ raw: String) {
        #expect(throws: BrookLinkError.self) { try BrookLink(parsing: raw) }
    }

    @Test func trimsWhitespace() throws {
        let link = try BrookLink(parsing: "  brook://server?password=hello&server=1.2.3.4%3A9999\n")
        #expect(link.host == "1.2.3.4")
    }

    // Pinning makes brook dial exactly the IP we routed outside the tunnel,
    // so a DNS change (CDN rotation) can't send the server connection into the tunnel.
    @Test func pinningServerLinkRewritesServerParam() throws {
        let link = try BrookLink(parsing: "brook://server?password=hello&server=myvps.example.com%3A9999")
        let pinned = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9"))
        #expect(pinned.kind == .server)
        #expect(pinned.host == "9.9.9.9")
        #expect(pinned.port == 9999)
        #expect(pinned.queryValue("password") == "hello")
    }

    @Test func pinningWssLinkSetsAddressAndKeepsHostForTLS() throws {
        let link = try BrookLink(parsing: "brook://wssserver?password=hello&wssserver=wss%3A%2F%2Fexample.com%3A8443%2Fws")
        let pinned = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9"))
        #expect(pinned.host == "example.com")
        #expect(pinned.dialHost == "9.9.9.9")
        #expect(pinned.queryValue("address") == "9.9.9.9:8443")
    }

    @Test func pinningIsNoOpWhenAlreadyAnIP() throws {
        let raw = "brook://server?password=hello&server=1.2.3.4%3A9999"
        let link = try BrookLink(parsing: raw)
        #expect(link.pinned(toIP: "1.2.3.4") == raw)
    }

    @Test func dialHostIsIPDetection() throws {
        #expect(try BrookLink(parsing: "brook://server?server=1.2.3.4%3A1").dialHostIsIPv4)
        #expect(try !BrookLink(parsing: "brook://server?server=a.example%3A1").dialHostIsIPv4)
    }
}
