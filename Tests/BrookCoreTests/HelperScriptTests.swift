import Foundation
import Testing

/// Exercises helper/brook-client-helper (the only code that runs as root) in dry-run mode:
/// commands are printed as "+ cmd args" instead of executed.
private struct HelperRun {
    let status: Int32
    let stdout: String
    let stderr: String
    var commands: [String] {
        stdout.split(separator: "\n").filter { $0.hasPrefix("+ ") }.map { String($0.dropFirst(2)) }
    }
}

private let helperPath: String = {
    // Tests/BrookCoreTests/HelperScriptTests.swift -> repo root
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("helper/brook-client-helper").path
}()

private func runHelper(_ args: [String], stateDir: URL) throws -> HelperRun {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [helperPath] + args
    p.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "BROOK_HELPER_DRYRUN": "1",
        "BROOK_HELPER_STATE_DIR": stateDir.path,
        "BROOK_HELPER_TUN": "utun199",
        "BROOK_HELPER_SERVICE": "Wi-Fi",
    ]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return HelperRun(status: p.terminationStatus,
                     stdout: String(decoding: o, as: UTF8.self),
                     stderr: String(decoding: e, as: UTF8.self))
}

private func freshStateDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let validUp = [
    "up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1",
    "--server", "5.6.7.8", "--net", "192.168.0.0/16", "--link", "224.0.0.0/4",
    "--dns", "8.8.8.8", "--watch", "4242",
]

@Suite(.serialized) struct HelperScriptTests {
    @Test func upRoutesServerAndBypassViaGatewayAndEverythingElseIntoTun() throws {
        let r = try runHelper(validUp, stateDir: freshStateDir())
        #expect(r.status == 0, "stderr: \(r.stderr)")
        let cmds = r.commands
        #expect(cmds.contains("route -n add -host 5.6.7.8 192.168.0.1"))
        #expect(cmds.contains("route -n add -net 192.168.0.0/16 192.168.0.1"))
        #expect(cmds.contains("route -n add -net 224.0.0.0/4 -interface en1"))
        #expect(cmds.contains("route -n add -net 0.0.0.0/1 -interface utun199"))
        #expect(cmds.contains("route -n add -net 128.0.0.0/1 -interface utun199"))
        #expect(cmds.contains { $0.contains("tun2socks") && $0.contains("-device utun199") && $0.contains("-proxy socks5://127.0.0.1:1080") })
        #expect(cmds.contains { $0.hasPrefix("ifconfig utun199 198.18.0.1 198.18.0.1") })
        #expect(cmds.contains("networksetup -setdnsservers Wi-Fi 8.8.8.8"))
        #expect(cmds.contains("watch 4242"))

        // Bypass/server routes must exist before the catch-all tunnel routes are installed,
        // otherwise there is a window where LAN and server traffic go into the tunnel.
        let serverIdx = try #require(cmds.firstIndex(of: "route -n add -host 5.6.7.8 192.168.0.1"))
        let lanIdx = try #require(cmds.firstIndex(of: "route -n add -net 192.168.0.0/16 192.168.0.1"))
        let catchAll = try #require(cmds.firstIndex(of: "route -n add -net 0.0.0.0/1 -interface utun199"))
        #expect(serverIdx < catchAll && lanIdx < catchAll)
    }

    /// Behind a local HTTP proxy (Px/cntlm on 127.0.0.1) there is no remote address to route
    /// outside the tunnel, so `up` must work without --server.
    @Test func upWithoutServerForLocalHTTPProxy() throws {
        let args = validUp.enumerated().filter { i, a in
            !(a == "--server" || (i > 0 && validUp[i - 1] == "--server"))
        }.map(\.element)
        let r = try runHelper(args, stateDir: freshStateDir())
        #expect(r.status == 0, "stderr: \(r.stderr)")
        #expect(!r.commands.contains { $0.hasPrefix("route -n add -host") })
        #expect(r.commands.contains("route -n add -net 0.0.0.0/1 -interface utun199"))
    }

    @Test func downUndoesWhatUpDid() throws {
        let dir = try freshStateDir()
        #expect(try runHelper(validUp, stateDir: dir).status == 0)
        let r = try runHelper(["down"], stateDir: dir)
        #expect(r.status == 0, "stderr: \(r.stderr)")
        let cmds = r.commands
        #expect(cmds.contains("route -n delete -host 5.6.7.8 192.168.0.1"))
        #expect(cmds.contains("route -n delete -net 192.168.0.0/16 192.168.0.1"))
        #expect(cmds.contains("route -n delete -net 224.0.0.0/4 -interface en1"))
        #expect(cmds.contains { $0.hasPrefix("networksetup -setdnsservers Wi-Fi") })
        #expect(cmds.contains { $0.hasPrefix("kill") })
        // Second down is a harmless no-op.
        let again = try runHelper(["down"], stateDir: dir)
        #expect(again.status == 0)
        #expect(!again.commands.contains { $0.hasPrefix("route") })
    }

    @Test func upWhileAlreadyUpTearsDownFirst() throws {
        let dir = try freshStateDir()
        #expect(try runHelper(validUp, stateDir: dir).status == 0)
        let r = try runHelper(validUp, stateDir: dir)
        #expect(r.status == 0)
        let cmds = r.commands
        let del = try #require(cmds.firstIndex(of: "route -n delete -host 5.6.7.8 192.168.0.1"))
        let add = try #require(cmds.firstIndex(of: "route -n add -host 5.6.7.8 192.168.0.1"))
        #expect(del < add)
    }

    @Test(arguments: [
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4;id", "--watch", "1"],
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1 -x", "--server", "1.2.3.4", "--watch", "1"],
        ["up", "--socks", "99999", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4", "--watch", "1"],
        ["up", "--socks", "1080", "--gateway", "$(id)", "--interface", "en1", "--server", "1.2.3.4", "--watch", "1"],
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4", "--net", "10.0.0.0/8 x", "--watch", "1"],
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4", "--dns", "`id`", "--watch", "1"],
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4", "--watch", "abc"],
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--watch", "1"],          // no server
        ["up", "--socks", "1080", "--gateway", "192.168.0.1", "--interface", "en1", "--server", "1.2.3.4"],  // no watch pid
        ["up", "--bogus", "1"],
        ["frobnicate"],
        [],
    ])
    func rejectsInvalidArgumentsWithoutRunningAnything(_ args: [String]) throws {
        let r = try runHelper(args, stateDir: freshStateDir())
        #expect(r.status == 2, "args \(args) -> \(r.status)")
        #expect(r.commands.isEmpty, "ran: \(r.commands)")
    }

    @Test func proxyOnAndOff() throws {
        let dir = try freshStateDir()
        let on = try runHelper([
            "proxy-on", "--interface", "en1", "--http", "1081", "--socks", "1080",
            "--bypass", "192.168.0.0/16", "--bypass", "10.0.0.0/8", "--watch", "7",
        ], stateDir: dir)
        #expect(on.status == 0, "stderr: \(on.stderr)")
        #expect(on.commands.contains("networksetup -setwebproxy Wi-Fi 127.0.0.1 1081"))
        #expect(on.commands.contains("networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 1081"))
        #expect(on.commands.contains("networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 1080"))
        #expect(on.commands.contains("networksetup -setproxybypassdomains Wi-Fi localhost 127.0.0.1 *.local 192.168.0.0/16 10.0.0.0/8"))

        let off = try runHelper(["down"], stateDir: dir)
        #expect(off.status == 0)
        #expect(off.commands.contains("networksetup -setwebproxystate Wi-Fi off"))
        #expect(off.commands.contains("networksetup -setsecurewebproxystate Wi-Fi off"))
        #expect(off.commands.contains("networksetup -setsocksfirewallproxystate Wi-Fi off"))
    }

    @Test func proxyOnRejectsInjection() throws {
        let r = try runHelper([
            "proxy-on", "--interface", "en1", "--http", "1081", "--socks", "1080",
            "--bypass", "*.local;id", "--watch", "7",
        ], stateDir: freshStateDir())
        #expect(r.status == 2)
        #expect(r.commands.isEmpty)
    }

    @Test func statusReportsStopped() throws {
        let r = try runHelper(["status"], stateDir: freshStateDir())
        #expect(r.stdout.contains("stopped"))
    }
}
