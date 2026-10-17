import AppKit
import BrookCore
import ServiceManagement
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
                case .outdated: "Outdated — reinstall"
                case .notInstalled: "Not installed (required)"
                }
            }
        }
    }

    func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let onSave: (AppConfig) -> Void
    let onInstallHelper: () -> Void

    var body: some View {
        Form {
            Section("Servers") {
                ForEach(model.profiles.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: model.selectedIndex == i ? "largecircle.fill.circle" : "circle")
                            .onTapGesture { model.selectedIndex = i }
                            .help("Use this server")
                        TextField("Name", text: $model.profiles[i].name).frame(width: 110)
                        TextField("brook://…", text: $model.profiles[i].link)
                            .font(.system(.body, design: .monospaced))
                        Button(role: .destructive) { model.removeProfile(i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Server (pastes a brook:// link from the clipboard)") { model.addProfile() }
            }

            Section("Connection") {
                Picker("Mode", selection: $model.mode) {
                    Text("Full device (TUN)").tag(ConnectionMode.tun)
                    Text("System proxy only").tag(ConnectionMode.proxy)
                }
                .pickerStyle(.segmented)
                Text(model.mode == .tun
                    ? "All traffic goes through Brook except the ranges below, which go straight to your router — so LAN devices (TV, NAS, printer, sdb) keep working."
                    : "Only apps that honour the macOS proxy use Brook. Command-line tools like sdb are never proxied.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Block public IPv6 while connected (prevents leaks; LAN IPv6 unaffected)", isOn: $model.blockIPv6)
                    .disabled(model.mode != .tun)
                TextField("DNS while connected (TUN)", text: $model.dnsText)
                    .help("Queried through the tunnel. Leave empty to keep your current DNS.")
                HStack {
                    TextField("SOCKS5 port", value: $model.socksPort, format: .number.grouping(.never))
                    TextField("HTTP port", value: $model.httpPort, format: .number.grouping(.never))
                }
            }

            Section("Bypass VPN for (one IPv4 address or CIDR per line)") {
                TextEditor(text: $model.bypassText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                Button("Reset to private networks") { model.bypassText = AppConfig.defaultBypass.joined(separator: "\n") }
            }

            Section("General") {
                Toggle("Connect when the app starts", isOn: $model.connectOnLaunch)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _ in model.applyLaunchAtLogin() }
                HStack {
                    Text("Network helper: \(model.helperStatus)")
                    Spacer()
                    Button(model.helperReady ? "Reinstall" : "Install…", action: onInstallHelper)
                }
            }

            if !model.errors.isEmpty {
                Section {
                    ForEach(model.errors, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
                }
            }

            HStack {
                Spacer()
                Button("Save") { onSave(model.config) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.errors.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 760)
        .onAppear { model.refreshHelper() }
    }
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
        }, onInstallHelper: {
            (NSApp.delegate as? AppDelegate)?.installHelper()
        })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Brook Client Settings"
        w.styleMask = [.titled, .closable, .resizable]
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

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        onClose()
    }
}
