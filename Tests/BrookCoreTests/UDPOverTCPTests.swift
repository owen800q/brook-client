import Foundation
import Testing
@testable import BrookCore

/// Live finding: the user's server passes TCP but drops UDP (cloud firewall), so macOS DNS
/// (UDP) died inside the tunnel and nothing resolved. brook's UDP-over-TCP fixes it.
@Suite struct UDPOverTCPTests {
    @Test func serverLinkGetsUDPOverTCP() throws {
        let link = try BrookLink(parsing: "brook://server?password=hello&server=myvps.example.com%3A9999")
        let out = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9", udpOverTCP: true))
        #expect(out.queryValue("udpovertcp") == "true")
        #expect(out.host == "9.9.9.9")
        #expect(out.queryValue("password") == "hello")
    }

    @Test func appliedEvenWhenServerIsAlreadyAnIP() throws {
        let link = try BrookLink(parsing: "brook://server?password=hello&server=1.2.3.4%3A9999")
        let out = try BrookLink(parsing: link.pinned(toIP: "1.2.3.4", udpOverTCP: true))
        #expect(out.queryValue("udpovertcp") == "true")
    }

    @Test func notDuplicatedWhenAlreadyPresent() throws {
        let raw = "brook://server?password=hello&server=1.2.3.4%3A9999&udpovertcp=true"
        let out = try BrookLink(parsing: raw).pinned(toIP: "1.2.3.4", udpOverTCP: true)
        #expect(out.components(separatedBy: "udpovertcp").count == 2)
    }

    @Test func quicUsesUDPOverStream() throws {
        let link = try BrookLink(parsing: "brook://quicserver?password=x&quicserver=quic%3A%2F%2Fexample.com%3A443")
        let out = try BrookLink(parsing: link.pinned(toIP: "9.9.9.9", udpOverTCP: true))
        #expect(out.queryValue("udpoverstream") == "true")
        #expect(out.queryValue("udpovertcp") == nil)
    }

    // ws/wss already carry UDP inside the websocket (TCP) stream.
    @Test func websocketLinksUnchanged() throws {
        let link = try BrookLink(parsing: "brook://wssserver?password=x&wssserver=wss%3A%2F%2F1.2.3.4%3A443%2Fws")
        #expect(link.pinned(toIP: "1.2.3.4", udpOverTCP: true) == link.raw)
    }

    @Test func offLeavesLinkAlone() throws {
        let raw = "brook://server?password=hello&server=1.2.3.4%3A9999"
        #expect(try BrookLink(parsing: raw).pinned(toIP: "1.2.3.4", udpOverTCP: false) == raw)
    }

    @Test func configDefaultsOnAndDecodesMissingKey() throws {
        #expect(AppConfig().udpOverTCP)
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mode":"tun"}"#.utf8))
        #expect(c.udpOverTCP)
    }
}
