import Foundation
import Testing

private let helper: String = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("helper/brook-client-helper").path

private func dryRun(_ args: [String], state: URL) throws -> (status: Int32, commands: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [helper] + args
    p.environment = ["BROOK_HELPER_DRYRUN": "1", "BROOK_HELPER_STATE_DIR": state.path,
                     "BROOK_HELPER_TUN": "utun199", "BROOK_HELPER_SERVICE": "Wi-Fi"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let cmds = String(decoding: data, as: UTF8.self).split(separator: "\n")
        .filter { $0.hasPrefix("+ ") }.map { String($0.dropFirst(2)) }
    return (p.terminationStatus, cmds)
}

private func stateDir(files: [String: String] = [:]) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bchr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (name, body) in files { try body.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return d
}

private let base = ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "5.6.7.8"]

@Suite(.serialized) struct HelperRegressionTests {
    @Test func blockIPv6InstallsAndRemovesRejectRoute() throws {
        let dir = try stateDir()
        let up = try dryRun(base + ["--ipv6", "block", "--watch", "1"], state: dir)
        #expect(up.status == 0)
        #expect(up.commands.contains("route -n add -inet6 -net 2000::/3 ::1 -reject"))
        let down = try dryRun(["down"], state: dir)
        #expect(down.commands.contains("route -n delete -inet6 -net 2000::/3 ::1 -reject"))
    }

    @Test(arguments: [
        ["--ipv6", "allow"],
        ["--net", "0.0.0.0/1"],
        ["--link", "0.0.0.0/0"],
        ["--net", "64.0.0.0/3"],
        ["--server", "0.0.0.0"],
    ])
    func rejectsDangerousValues(_ extra: [String]) throws {
        let r = try dryRun(base + extra + ["--watch", "1"], state: stateDir())
        #expect(r.status == 2, "\(extra)")
        #expect(r.commands.isEmpty)
    }

    @Test func rejectsUnspecifiedGateway() throws {
        let r = try dryRun(["up", "--socks", "1080", "--gateway", "0.0.0.0", "--interface", "en1", "--server", "5.6.7.8", "--watch", "1"],
                           state: stateDir())
        #expect(r.status == 2)
    }

    // A user's manually configured IPv6 DNS must survive a connect/disconnect cycle.
    @Test func restoresIPv6DNS() throws {
        let dir = try stateDir(files: [
            "state": "mode tun\n",
            "service": "Wi-Fi\n",
            "dns_prev": "2001:4860:4860::8888 8.8.8.8\n",
        ])
        let r = try dryRun(["down"], state: dir)
        #expect(r.commands.contains("networksetup -setdnsservers Wi-Fi 2001:4860:4860::8888 8.8.8.8"))
    }

    @Test func tamperedDNSFallsBackToEmpty() throws {
        let dir = try stateDir(files: ["state": "mode tun\n", "service": "Wi-Fi\n", "dns_prev": "8.8.8.8;id\n"])
        let r = try dryRun(["down"], state: dir)
        #expect(r.commands.contains("networksetup -setdnsservers Wi-Fi Empty"))
    }

    @Test func restoresProxyBypassWithAngleBracketEntries() throws {
        let dir = try stateDir(files: ["state": "mode proxy\nproxy\n", "service": "Wi-Fi\n", "bypass_prev": "*.local <local> 169.254/16\n"])
        let r = try dryRun(["down"], state: dir)
        #expect(r.commands.contains("networksetup -setproxybypassdomains Wi-Fi *.local <local> 169.254/16"))
    }
}
