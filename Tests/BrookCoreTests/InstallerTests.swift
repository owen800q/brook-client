import Foundation
import Testing

private let installer: String = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("helper/install-helper.sh")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}()

private func assignment(_ name: String) -> String? {
    installer.split(separator: "\n").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
}

@Suite struct InstallerTests {
    // sudo's #includedir silently skips files whose names contain "." or end in "~".
    // The original "com.brookclient" was ignored, so the helper always needed a password.
    @Test func sudoersFileNameIsNotSkippedByIncludedir() throws {
        let path = try #require(assignment("SUDOERS"))
        #expect(path.hasPrefix("/etc/sudoers.d/"))
        let name = String(path.dropFirst("/etc/sudoers.d/".count))
        #expect(!name.isEmpty && !name.contains(".") && !name.hasSuffix("~"), "sudo would ignore \(name)")
    }

    // Upgrades must remove the old, ignored file.
    @Test func removesLegacyDottedSudoersFile() {
        #expect(installer.contains("/etc/sudoers.d/com.brookclient\""))
        #expect(installer.contains("rm -f \"$LEGACY_SUDOERS\""))
    }

    // Install must prove the rule is actually in effect instead of reporting success.
    @Test func verifiesRuleIsEffective() {
        #expect(installer.contains("sudo -n -l -U \"$user\" \"$HELPER\""))
    }
}
