import Foundation
import ServiceManagement

/// "Launch at login". Uses SMAppService on macOS 13+, and a per-user LaunchAgent on macOS 12,
/// where SMAppService does not exist.
enum LoginItem {
    private static let label = "com.brookclient.app.loginitem"

    private static var agentURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    private static var agentInstalled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return agentInstalled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            // Drop an agent left over from running on macOS 12 so the app isn't launched twice.
            try? removeAgent()
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } else if enabled {
            try installAgent()
        } else {
            try removeAgent()
        }
    }

    private static func installAgent() throws {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.brookclient.app"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-b", bundleID],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() throws {
        guard agentInstalled else { return }
        try FileManager.default.removeItem(at: agentURL)
    }
}
