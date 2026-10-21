import AppKit
import BrookCore
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var profiles: [Profile]
    @Published var selectedIndex: Int?
    @Published var mode: ConnectionMode
    @Published var bypassText: String
    @Published var dnsText: String
    @Published var socksPort: Int
    @Published var httpPort: Int
    @Published var connectOnLaunch: Bool
    @Published var blockIPv6: Bool
    @Published var udpOverTCP: Bool
    @Published var launchAtLogin: Bool
    @Published var helperStatus = "Checking…"
    @Published var helperReady = false

    init(_ c: AppConfig) {
        profiles = c.profiles
        selectedIndex = c.selectedIndex
        mode = c.mode
        bypassText = c.bypassCIDRs.joined(separator: "\n")
        dnsText = c.dns.joined(separator: ", ")
        socksPort = c.socksPort
        httpPort = c.httpPort
        connectOnLaunch = c.connectOnLaunch
        blockIPv6 = c.blockIPv6
        udpOverTCP = c.udpOverTCP
        launchAtLogin = LoginItem.isEnabled
    }

    var config: AppConfig {
        var c = AppConfig()
        c.profiles = profiles
        c.selectedIndex = selectedIndex.flatMap { profiles.indices.contains($0) ? $0 : nil } ?? (profiles.isEmpty ? nil : 0)
        c.mode = mode
        c.bypassCIDRs = Self.tokens(bypassText)
        c.dns = Self.tokens(dnsText)
        c.socksPort = socksPort
        c.httpPort = httpPort
        c.connectOnLaunch = connectOnLaunch
        c.blockIPv6 = blockIPv6
        c.udpOverTCP = udpOverTCP
        return c
    }

    var errors: [String] { config.validationErrors() }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    func addProfile() {
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = clip.hasPrefix("brook://") ? clip : ""
        let name = (try? BrookLink(parsing: link))?.name ?? "Server \(profiles.count + 1)"
        profiles.append(Profile(name: name, link: link))
        if selectedIndex == nil { selectedIndex = profiles.count - 1 }
    }

    func removeProfile(_ i: Int) {
        profiles.remove(at: i)
        if let s = selectedIndex, s >= profiles.count { selectedIndex = profiles.isEmpty ? nil : profiles.count - 1 }
    }

    func refreshHelper() {
        Task.detached {
            let s = Helper.status()
            await MainActor.run {
                self.helperReady = s == .ready
                self.helperStatus = switch s {
                case .ready: "Installed"
                case .notAuthorized: "Permission rule not active — reinstall"
                case .outdated: "Outdated — reinstall"
                case .notInstalled: "Not installed (required)"
                }
            }
        }
    }

    func applyLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(launchAtLogin)
        } catch {
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let onSave: (AppConfig) -> Void
    let onCancel: () -> Void
    let onInstallHelper: () -> Void

    var body: some View {
        // The form scrolls; the Save/Cancel bar stays pinned at the bottom so it is
        // always reachable, even on short screens like a 13" MacBook Air.
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                form
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        // The ideal width sets the window's opening width; long text would otherwise ask for
        // a window as wide as the screen.
        .frame(minWidth: SettingsLayout.minWidth, idealWidth: SettingsLayout.idealWidth, maxWidth: .infinity,
               minHeight: SettingsLayout.minHeight, maxHeight: .infinity)
        .onAppear { model.refreshHelper() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let first = model.errors.first {
                Label(model.errors.count > 1 ? "\(first) (+\(model.errors.count - 1) more)" : first,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(model.errors.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Save") { onSave(model.config) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.errors.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // A plain stack rather than `Form`: on macOS 12 a Form lays out at its unwrapped width and
    // clips on both sides, and macOS 13+ draws it differently, so CI (macOS 15) never saw the bug.
    // One layout on every version keeps the CI layout test meaningful.
    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Servers") {
                ForEach(model.profiles.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Button { model.selectedIndex = i } label: {
                            Image(systemName: model.selectedIndex == i ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.selectedIndex == i ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Use this server")
                        TextField("Name", text: $model.profiles[i].name)
                            .frame(width: 100)
                        // Bound the width: an unbounded field grows to fit the whole link.
                        TextField("brook://…", text: $model.profiles[i].link)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 160, maxWidth: .infinity)
                        Button(role: .destructive) { model.removeProfile(i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this server")
                    }
                }
                Button("Add Server") { model.addProfile() }
                    .help("Pastes a brook:// link from the clipboard")
                caption("Copy a brook:// link first; Add Server pastes it from the clipboard.")
            }

            section("Connection") {
                field("Mode") {
                    Picker("Mode", selection: $model.mode) {
                        Text("Full device (TUN)").tag(ConnectionMode.tun)
                        Text("System proxy only").tag(ConnectionMode.proxy)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                caption(model.mode == .tun
                    ? "All traffic goes through Brook except the ranges below, which go straight to your router — so LAN devices (TV, NAS, printer, sdb) keep working."
                    : "Only apps that honour the macOS proxy use Brook. Command-line tools like sdb are never proxied.")
                toggle("UDP over TCP (needed if your server's firewall blocks UDP — otherwise DNS fails)", isOn: $model.udpOverTCP)
                toggle("Block public IPv6 while connected (prevents leaks; LAN IPv6 unaffected)", isOn: $model.blockIPv6)
                    .disabled(model.mode != .tun)
                field("DNS while connected (TUN)") {
                    TextField("8.8.8.8, 1.1.1.1", text: $model.dnsText)
                        .help("Queried through the tunnel. Leave empty to keep your current DNS.")
                }
                HStack(alignment: .top, spacing: 12) {
                    field("SOCKS5 port") {
                        TextField("1080", value: $model.socksPort, format: .number.grouping(.never))
                    }
                    field("HTTP port") {
                        TextField("1081", value: $model.httpPort, format: .number.grouping(.never))
                    }
                }
            }

            section("Bypass VPN for") {
                caption("One IPv4 address or CIDR per line.")
                TextEditor(text: $model.bypassText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("Reset to private networks") { model.bypassText = AppConfig.defaultBypass.joined(separator: "\n") }
            }

            section("General") {
                toggle("Connect when the app starts", isOn: $model.connectOnLaunch)
                toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _ in model.applyLaunchAtLogin() }
                HStack {
                    wrapping("Network helper: \(model.helperStatus)")
                    Button(model.helperReady ? "Reinstall" : "Install…", action: onInstallHelper)
                }
            }

            if !model.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.errors, id: \.self) { wrapping($0).foregroundStyle(.red).font(.caption) }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    /// A label above its control, so long labels never push the control off the window.
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            wrapping(label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { wrapping(label) }
    }

    private func caption(_ s: String) -> some View {
        wrapping(s).font(.caption).foregroundStyle(.secondary)
    }

    /// Text that wraps to the available width instead of asking for one long line.
    private func wrapping(_ s: String) -> some View {
        Text(s)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Window size limits. The minimum width fits the name and link fields side by side; text wraps.
private enum SettingsLayout {
    static let minWidth: CGFloat = 480
    static let idealWidth: CGFloat = 600
    static let minHeight: CGFloat = 320
    static let idealHeight: CGFloat = 760
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel
    private let onClose: () -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void, onClose: @escaping () -> Void) {
        model = SettingsModel(config)
        self.onClose = onClose
        super.init()
        let view = SettingsView(model: model, onSave: { [weak self] c in
            onSave(c)
            self?.window?.close()
        }, onCancel: { [weak self] in
            self?.window?.close()
        }, onInstallHelper: {
            (NSApp.delegate as? AppDelegate)?.installHelper()
        })
        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) {
            // Only enforce the minimum size; the initial size is set below.
            hosting.sizingOptions = [.minSize]
        }
        let w = NSWindow(contentViewController: hosting)
        w.title = "Brook Client Settings"
        w.styleMask = [.titled, .closable, .resizable]
        w.contentMinSize = NSSize(width: SettingsLayout.minWidth, height: SettingsLayout.minHeight)
        w.setContentSize(Self.initialContentSize())
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshHelperStatus() { model.refreshHelper() }

    /// The ideal size, kept within the screen's usable area (minus menu bar, Dock and title bar).
    /// The form scrolls when it is taller than the window.
    private static func initialContentSize() -> NSSize {
        let ideal = NSSize(width: SettingsLayout.idealWidth, height: SettingsLayout.idealHeight)
        guard let visible = NSScreen.main?.visibleFrame else { return ideal }
        return NSSize(width: max(min(ideal.width, visible.width - 40), SettingsLayout.minWidth),
                      height: max(min(ideal.height, visible.height - 60), SettingsLayout.minHeight))
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        onClose()
    }
}
