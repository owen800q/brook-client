import AppKit
import BrookCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigStore.standard
    private var config = AppConfig()
    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { config = try store.load() } catch { alert("Could not read settings", "\(error.localizedDescription)\nUsing defaults.") }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        engine.onChange = { [weak self] state in self?.stateChanged(state) }
        updateIcon()

        // Clean up after a previous crash (no-op if nothing is up).
        Task.detached {
            if FileManager.default.isExecutableFile(atPath: Paths.installedHelper) { _ = Helper.run(["down"]) }
        }
        if config.profiles.isEmpty {
            openSettings()
        } else if config.connectOnLaunch {
            engine.connect(config)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine.shutdownSync()
        return .terminateNow
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine))
        if case let .connected(mode, _, detail) = engine.state {
            menu.addItem(disabled("  \(detail)"))
            if mode == .tun {
                let ips = engine.serverIPs.joined(separator: ", ")
                menu.addItem(disabled("  Server \(ips) · LAN bypassed"))
            }
        }
        menu.addItem(.separator())

        if engine.isActive {
            menu.addItem(item("Disconnect", #selector(toggleConnection), key: "d"))
        } else {
            let connect = item("Connect", #selector(toggleConnection), key: "c")
            connect.isEnabled = config.selectedProfile != nil
            menu.addItem(connect)
        }

        let servers = NSMenu()
        if config.profiles.isEmpty { servers.addItem(disabled("No servers — open Settings")) }
        for (i, p) in config.profiles.enumerated() {
            let it = item(p.name, #selector(selectProfile(_:)))
            it.tag = i
            it.state = config.selectedIndex == i ? .on : .off
            servers.addItem(it)
        }
        let serversItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
        serversItem.submenu = servers
        menu.addItem(serversItem)

        let modes = NSMenu()
        for (mode, title) in [(ConnectionMode.tun, "Full Device (TUN) — LAN bypassed"), (.proxy, "System Proxy Only")] {
            let it = item(title, #selector(selectMode(_:)))
            it.representedObject = mode.rawValue
            it.state = config.mode == mode ? .on : .off
            modes.addItem(it)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modes
        menu.addItem(modeItem)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsAction), key: ","))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Brook Client", #selector(quit), key: "q"))
    }

    private var statusLine: String {
        switch engine.state {
        case .disconnected: "Disconnected"
        case let .connecting(what): "Connecting: \(what)"
        case let .connected(_, profile, _): "Connected — \(profile)"
        case let .failed(msg): "Error: \(msg)"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Actions

    @objc private func toggleConnection() {
        if engine.isActive { engine.disconnect() } else { engine.connect(config) }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        config.selectedIndex = sender.tag
        persistAndReconnect()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ConnectionMode(rawValue: raw) else { return }
        config.mode = mode
        persistAndReconnect()
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.brookLog.path) {
            FileManager.default.createFile(atPath: Paths.brookLog.path, contents: nil)
        }
        NSWorkspace.shared.open(Paths.brookLog)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openSettings() {
        if let settings { settings.show(); return }
        let controller = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.config = newConfig
            self?.persistAndReconnect()
        } onClose: { [weak self] in
            self?.settings = nil // release the window and its SwiftUI tree to keep memory low
        }
        settings = controller
        controller.show()
    }

    private func persistAndReconnect() {
        do { try store.save(config) } catch { alert("Could not save settings", error.localizedDescription) }
        if engine.isActive { engine.connect(config) }
    }

    // MARK: - State

    private func stateChanged(_ state: Engine.State) {
        updateIcon()
        if case let .failed(msg) = state, msg.contains("helper") {
            offerHelperInstall(reason: msg)
        }
    }

    private func updateIcon() {
        let symbol: String
        switch engine.state {
        case .connected, .connecting: symbol = "shield.lefthalf.filled"
        case .failed: symbol = "exclamationmark.shield"
        case .disconnected: symbol = "shield"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Brook Client")
        image?.isTemplate = true
        statusItem.button?.image = image
        if case .connecting = engine.state { statusItem.button?.alphaValue = 0.5 } else { statusItem.button?.alphaValue = 1 }
    }

    func offerHelperInstall(reason: String) {
        let a = NSAlert()
        a.messageText = "Install network helper?"
        a.informativeText = "\(reason)\n\nBrook Client needs a small root helper to create the tunnel and keep your home network (LAN) outside it. You will be asked for your password once."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        installHelper()
    }

    func installHelper() {
        Task.detached {
            let out = Helper.install()
            await MainActor.run {
                if out.ok {
                    self.alert("Network helper installed", "You can connect now.")
                } else if !out.stderr.contains("User canceled") {
                    self.alert("Helper installation failed", out.stderr)
                }
                self.settings?.refreshHelperStatus()
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
