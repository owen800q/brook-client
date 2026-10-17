import Foundation

/// Talks to the root helper through `sudo -n` (allowed by the sudoers rule the installer writes).
enum Helper {
    enum Status { case notInstalled, outdated, ready }

    private static var bundledHelper: URL { Paths.resources.appendingPathComponent("brook-client-helper") }
    private static var bundledTun2socks: URL { Paths.resources.appendingPathComponent("tun2socks") }

    static func status() -> Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Paths.installedHelper), fm.isExecutableFile(atPath: Paths.installedTun2socks),
              System.run("/usr/bin/sudo", ["-n", "-l", Paths.installedHelper]).ok else { return .notInstalled }
        // A newer app build ships a newer helper; compare contents.
        if let bundled = try? Data(contentsOf: bundledHelper),
           let installed = try? Data(contentsOf: URL(fileURLWithPath: Paths.installedHelper)), bundled != installed {
            return .outdated
        }
        return .ready
    }

    /// Runs the installer as root via the standard macOS admin prompt.
    static func install() -> System.Output {
        let installer = Paths.resources.appendingPathComponent("install-helper.sh").path
        guard FileManager.default.fileExists(atPath: bundledHelper.path),
              FileManager.default.fileExists(atPath: bundledTun2socks.path) else {
            return System.Output(status: 1, stdout: "", stderr: "Helper files are missing from the app bundle; build with scripts/build-app.sh.")
        }
        let cmd = ["/bin/sh", installer, "install", Paths.resources.path, NSUserName()].map(shellQuote).joined(separator: " ")
        return asAdmin(cmd)
    }

    static func uninstall() -> System.Output {
        let installer = Paths.resources.appendingPathComponent("install-helper.sh").path
        return asAdmin(["/bin/sh", installer, "uninstall"].map(shellQuote).joined(separator: " "))
    }

    static func run(_ args: [String]) -> System.Output {
        System.run("/usr/bin/sudo", ["-n", Paths.installedHelper] + args)
    }

    private static func asAdmin(_ shellCommand: String) -> System.Output {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"Brook Client needs to install its network helper.\" with administrator privileges"
        return System.run("/usr/bin/osascript", ["-e", script])
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
