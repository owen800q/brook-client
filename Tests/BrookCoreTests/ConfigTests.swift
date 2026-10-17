import Foundation
import Testing
@testable import BrookCore

@Suite struct ConfigTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("brookclient-test-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
    }

    @Test func defaultsBypassPrivateNetworks() {
        let c = AppConfig()
        for cidr in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4"] {
            #expect(c.bypassCIDRs.contains(cidr))
        }
        #expect(c.mode == .tun)
        #expect(c.socksPort == 1080)
        #expect(c.httpPort == 1081)
        #expect(c.dns == ["8.8.8.8", "1.1.1.1"])
        #expect(c.profiles.isEmpty)
        #expect(c.selectedProfile == nil)
    }

    @Test func missingFileLoadsDefaults() throws {
        let store = ConfigStore(url: tempURL())
        #expect(try store.load() == AppConfig())
    }

    @Test func roundTripAndPrivatePermissions() throws {
        let url = tempURL()
        let store = ConfigStore(url: url)
        var c = AppConfig()
        c.profiles = [Profile(name: "HK", link: "brook://server?password=hello&server=1.2.3.4%3A9999")]
        c.selectedIndex = 0
        c.mode = .proxy
        c.bypassCIDRs = ["192.168.0.0/16"]
        try store.save(c)
        #expect(try store.load() == c)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600) // links contain passwords
        #expect(try store.load().selectedProfile?.name == "HK")
    }

    @Test func partialJSONFillsDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mode":"proxy"}"#.utf8).write(to: url)
        let c = try ConfigStore(url: url).load()
        #expect(c.mode == .proxy)
        #expect(c.bypassCIDRs == AppConfig().bypassCIDRs)
    }

    @Test func selectedProfileOutOfRangeIsNil() {
        var c = AppConfig()
        c.profiles = [Profile(name: "a", link: "x")]
        c.selectedIndex = 3
        #expect(c.selectedProfile == nil)
    }

    @Test func validationReportsProblems() {
        var c = AppConfig()
        c.profiles = [Profile(name: "bad", link: "nope")]
        c.selectedIndex = 0
        c.bypassCIDRs = ["192.168.0.0/16", "bogus"]
        c.dns = ["8.8.8.8", "x"]
        let problems = c.validationErrors()
        #expect(problems.count == 3)
        #expect(problems.contains { $0.contains("bogus") })
        #expect(problems.contains { $0.contains("bad") })
        #expect(problems.contains { $0.contains("x") })
        #expect(AppConfig().validationErrors().isEmpty)
    }
}
