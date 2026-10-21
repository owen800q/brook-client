import BrookCore
import Foundation
import Network

/// Owns the brook process and the helper-managed tunnel/proxy; keeps them healthy.
@MainActor
final class Engine {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected(mode: ConnectionMode, profile: String, detail: String)
        case failed(String)
    }

    struct Failure: Error {
        let message: String
        /// Network blips and server hiccups are retried; config/helper problems are not.
        var retryable = false
        static func transient(_ m: String) -> Failure { Failure(message: m, retryable: true) }
    }

    private struct Session {
        let config: AppConfig
        let gateway: PhysicalGateway
        let tun: String?
        let process: Process
        let serverIPs: [String]
        /// Local HTTP CONNECT relay, when an upstream (corporate) proxy is configured.
        let relay: ConnectRelay?
    }

    private(set) var state: State = .disconnected { didSet { if state != oldValue { onChange?(state) } } }
    var onChange: ((State) -> Void)?

    private var session: Session?
    private var pendingConfig: AppConfig?
    private var wantConnected = false
    private var retries = 0
    private var generation = 0 // bumps to invalidate in-flight async work
    private var healthTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: DispatchWorkItem?

    var isActive: Bool {
        switch state {
        case .connecting, .connected: true
        default: false
        }
    }

    var serverIPs: [String] { session?.serverIPs ?? [] }

    // MARK: - Public

    func connect(_ config: AppConfig) {
        wantConnected = true
        retries = 0
        start(config)
    }

    func disconnect() {
        wantConnected = false
        generation += 1
        let old = session
        session = nil
        stopMonitoring()
        state = .disconnected
        Task.detached { Engine.tearDown(old) }
    }

    /// Blocking teardown used when the app quits.
    func shutdownSync() {
        wantConnected = false
        generation += 1
        stopMonitoring()
        Engine.tearDown(session)
        session = nil
    }

    // MARK: - Lifecycle

    private func start(_ config: AppConfig) {
        generation += 1
        let gen = generation
        guard let profile = config.selectedProfile else {
            state = .failed("No server selected")
            return
        }
        pendingConfig = config
        state = .connecting(profile.name)
        let old = session
        session = nil
        Task.detached { [weak self] in
            Engine.tearDown(old)
            let result = Engine.bringUp(config: config) { [weak self] process in
                Task { @MainActor in self?.processExited(process) }
            }
            await self?.finishStart(gen: gen, config: config, result: result)
        }
    }

    private func finishStart(gen: Int, config: AppConfig, result: Result<Session, Failure>) {
        guard gen == generation else {
            // Superseded (user disconnected or reconnected meanwhile): undo what we just built.
            if case let .success(s) = result { Task.detached { Engine.tearDown(s) } }
            return
        }
        switch result {
        case let .success(s):
            session = s
            retries = 0
            let name = config.selectedProfile?.name ?? "?"
            var detail = s.tun.map { "TUN \($0) via \(s.gateway.interface)" } ?? "System proxy on \(s.gateway.interface)"
            if let p = config.parsedUpstreamProxy { detail += ", through HTTP proxy \(p.host):\(p.port)" }
            state = .connected(mode: config.mode, profile: name, detail: detail)
            startMonitoring()
        case let .failure(f):
            fail(f)
        }
    }

    private func fail(_ failure: Failure) {
        let old = session
        session = nil
        stopMonitoring()
        Task.detached { Engine.tearDown(old) }
        // Retry transient failures (server unreachable, network blip), but not config/helper problems.
        if wantConnected, failure.retryable, retries < 5, let config = pendingConfig {
            retries += 1
            let delay = Double(min(2 << retries, 30))
            state = .connecting("Retrying in \(Int(delay))s — \(failure.message)")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, gen == self.generation, self.wantConnected else { return }
                self.start(config)
            }
        } else {
            wantConnected = false
            state = .failed(failure.message)
        }
    }

    private func processExited(_ process: Process) {
        guard let s = session, s.process === process else { return }
        fail(.transient("brook exited (status \(process.terminationStatus)); see log"))
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.networkChanged() }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathDebounce?.cancel()
    }

    private func checkHealth() {
        guard let s = session else { return }
        if let tun = s.tun, !System.interfaceExists(tun) { fail(.transient("Tunnel interface \(tun) disappeared")) }
    }

    /// Wi-Fi switch, cable unplugged, etc.: if the physical gateway changed, rebuild routes.
    private func networkChanged() {
        pathDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.session else { return }
            let gen = self.generation
            Task.detached {
                let gw = PhysicalGateway.parse(netstat: System.routingTable())
                await MainActor.run {
                    guard gen == self.generation, let gw, gw != s.gateway else { return }
                    self.retries = 0
                    self.start(s.config)
                }
            }
        }
        pathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Blocking work (background)

    private nonisolated static func bringUp(config: AppConfig, onExit: @escaping @Sendable (Process) -> Void) -> Result<Session, Failure> {
        guard let profile = config.selectedProfile else { return .failure(Failure(message: "No server selected")) }
        let link: BrookLink
        do { link = try BrookLink(parsing: profile.link) } catch {
            return .failure(Failure(message: "Invalid brook link for '\(profile.name)'"))
        }
        let problems = config.validationErrors()
        if !problems.isEmpty { return .failure(Failure(message: "" + problems.joined(separator: "; "))) }
        guard let brookPath = Paths.brook else { return .failure(Failure(message: "brook binary not found")) }

        switch Helper.status() {
        case .notInstalled: return .failure(Failure(message: "Network helper not installed"))
        case .notAuthorized: return .failure(Failure(message: "Network helper permission is not active; please reinstall the helper"))
        case .outdated: return .failure(Failure(message: "Network helper is outdated; please reinstall the helper"))
        case .ready: break
        }

        let table = System.routingTable()
        if PhysicalGateway.foreignTunnelOwnsDefault(netstat: table, ownTunnel: nil) {
            return .failure(Failure(message: "Another VPN (e.g. the official Brook app) is connected. Disconnect it first."))
        }
        guard let gateway = PhysicalGateway.parse(netstat: table) else {
            return .failure(.transient("No network connection"))
        }

        // Without a proxy, brook dials the server IP, which gets a host route outside the tunnel.
        // With one, brook dials our loopback relay, the relay dials the proxy (that IP gets the route
        // instead), and the proxy resolves the server name, since company DNS often can't.
        let upstream = config.parsedUpstreamProxy
        let ips: [String]
        var relay: ConnectRelay?
        let brookLink: String
        if let upstream {
            ips = upstream.hostIsIPv4 ? [upstream.host] : System.resolveIPv4(upstream.host)
            guard let proxyIP = ips.first else { return .failure(.transient("Cannot resolve HTTP proxy \(upstream.host)")) }
            let target = "\(link.dialHost):\(link.dialPort)"
            if let f = ConnectRelay.probe(proxy: upstream, proxyIP: proxyIP, targetHost: link.dialHost, targetPort: link.dialPort) {
                return .failure(Failure(message: f.message(target: target), retryable: f.isRetryable))
            }
            do {
                relay = try ConnectRelay(proxy: upstream, proxyIP: proxyIP, targetHost: link.dialHost, targetPort: link.dialPort,
                                         log: { Engine.appendLog($0) })
            } catch {
                let msg = (error as? ProxyFailure)?.message(target: target) ?? "\(error)"
                return .failure(Failure(message: msg))
            }
            brookLink = link.relayed(toLocalPort: relay!.port)
        } else {
            ips = link.dialHostIsIPv4 ? [link.dialHost] : System.resolveIPv4(link.dialHost)
            guard let pinIP = ips.first else { return .failure(.transient("Cannot resolve \(link.dialHost)")) }
            brookLink = link.pinned(toIP: pinIP, udpOverTCP: config.udpOverTCP)
        }
        // Anything that fails from here on must also close the relay.
        func failed(_ f: Failure) -> Result<Session, Failure> {
            relay?.stop()
            return .failure(f)
        }

        var ports = [config.socksPort]
        if config.mode == .proxy { ports.append(config.httpPort) }
        for p in ports where System.isListening(port: p) {
            return failed(Failure(message: "Port \(p) is already in use by another program"))
        }

        // brook runs unprivileged; only routing/DNS/proxy changes go through the helper.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brookPath)
        var args = ["connect", "--link", brookLink, "--socks5", "127.0.0.1:\(config.socksPort)"]
        if config.mode == .proxy { args += ["--http", "127.0.0.1:\(config.httpPort)"] }
        process.arguments = args
        let log = openLog()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = onExit
        do { try process.run() } catch { return failed(Failure(message: "Cannot start brook: \(error.localizedDescription)")) }

        let deadline = Date().addingTimeInterval(6)
        while !ports.allSatisfy(System.isListening(port:)) {
            if !process.isRunning { return failed(.transient("brook failed to start: \(logTail())")) }
            if Date() > deadline { process.terminate(); return failed(.transient("brook did not open its local proxy")) }
            usleep(100_000)
        }

        let helperArgs: [String]
        do {
            switch config.mode {
            case .tun:
                helperArgs = try TunnelPlan(serverIPs: ips, gateway: gateway, bypass: config.bypassCIDRs, dns: config.dns,
                                            socksPort: config.socksPort, watchPID: getpid(), blockIPv6: config.blockIPv6,
                                            allowNoServer: upstream != nil).helperArguments
            case .proxy:
                helperArgs = try ProxyPlan(interface: gateway.interface, httpPort: config.httpPort, socksPort: config.socksPort,
                                           bypass: config.bypassCIDRs, watchPID: getpid()).helperArguments
            }
        } catch {
            process.terminate()
            return failed(Failure(message: "Invalid settings: \(error)"))
        }

        let out = Helper.run(helperArgs)
        guard out.ok else {
            process.terminate()
            let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return failed(Failure(message: "Helper failed: \(msg.isEmpty ? "status \(out.status)" : msg)"))
        }
        // Helper prints "tun utunN" or "proxy <service>".
        let words = out.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        let tun = words.first == "tun" ? words.dropFirst().first : nil
        return .success(Session(config: config, gateway: gateway, tun: tun, process: process, serverIPs: ips, relay: relay))
    }

    private nonisolated static func tearDown(_ session: Session?) {
        session?.relay?.stop()
        if let process = session?.process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        // Idempotent; also cleans up after a crash of a previous app instance.
        if FileManager.default.isExecutableFile(atPath: Paths.installedHelper) {
            _ = Helper.run(["down"])
        }
    }

    private nonisolated static func openLog() -> FileHandle {
        let url = Paths.brookLog
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if !fm.fileExists(atPath: url.path) || size > 1_000_000 {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        h.seekToEndOfFile()
        h.write(Data("--- \(Date()) brook connect\n".utf8))
        return h
    }

    /// Relay problems go into brook.log next to brook's own output.
    private nonisolated static func appendLog(_ line: String) {
        guard let h = try? FileHandle(forWritingTo: Paths.brookLog) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(Date()) \(line)\n".utf8))
        try? h.close()
    }

    private nonisolated static func logTail() -> String {
        let text = (try? String(contentsOf: Paths.brookLog, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").suffix(2).joined(separator: " | ")
        return lines.isEmpty ? "no output" : String(lines.suffix(300))
    }
}
