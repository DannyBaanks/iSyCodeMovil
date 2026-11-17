import Foundation
import Darwin
#if canImport(idevice)
import idevice
#endif

/// Detects whether a developer loopback VPN (e.g. LocalDevVPN on 10.7.0.1) or Tailscale is active,
/// stores the user's `pairingFile.plist`, and talks to this iPhone's CoreDevice services via `jkcoxson/idevice` (MIT).
@MainActor
public final class LoopbackDeviceSession: ObservableObject {
    public static let shared = LoopbackDeviceSession()

    @Published public private(set) var hasPairingFile = false
    @Published public private(set) var loopbackVPNActive = false
    @Published public private(set) var tailscaleActive = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var errorMessage: String?

    private init() {
        refreshState()
    }

    public var pairingFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("pairingFile.plist")
    }

    public func refreshState() {
        hasPairingFile = FileManager.default.fileExists(atPath: pairingFileURL.path)
        let interfaces = Self.activeTunnelIPv4Addresses()
        loopbackVPNActive = interfaces.contains { $0.hasPrefix("10.7.") }
        tailscaleActive = interfaces.contains { $0.hasPrefix("100.") }
    }

    public func importPairingFile(from url: URL) {
        errorMessage = nil
        statusMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                errorMessage = "El archivo está vacío."
                return
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               plist["public_key"] == nil || plist["private_key"] == nil {
                errorMessage = "Este .plist no es de RemotePairing (falta public_key/private_key). No uses el de /var/lib/lockdown; genéralo con: idevice-tools rppairing pair iSyCodeMovil pairingFile.plist"
                return
            }
            let dir = pairingFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: pairingFileURL, options: .atomic)
            refreshState()
            statusMessage = "Archivo de emparejamiento guardado (\(data.count / 1024) KB)."
        } catch {
            errorMessage = "No se pudo importar: \(error.localizedDescription)"
        }
    }

    public func removePairingFile() {
        try? FileManager.default.removeItem(at: pairingFileURL)
        refreshState()
        statusMessage = "Archivo de emparejamiento eliminado."
    }

    /// Launches WebDriverAgent on this iPhone through CoreDevice's AppService over the loopback VPN,
    /// then polls local WDA (`127.0.0.1:8100/status`) so the user can switch back to Tailscale if needed.
    public func launchWDAOverLoopback() async {
        refreshState()
        errorMessage = nil
        statusMessage = nil
        guard hasPairingFile else {
            errorMessage = "Primero importa tu pairingFile.plist."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let pairingPath = pairingFileURL.path
            statusMessage = "Abriendo túnel RemotePairing en 10.7.0.1…"
            let launchedBundle = try await withTimeout(seconds: 15, label: "El túnel RemotePairing tardó demasiado (>15s). Verifica que LocalDevVPN esté activa y el pairingFile.plist sea de este iPhone.") {
                try await Task.detached(priority: .userInitiated) {
                    try Self.launchWDASync(pairingPath: pairingPath)
                }.value
            }
            statusMessage = "Se lanzó \(launchedBundle). Comprobando WDA en 127.0.0.1:8100…"
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if (try? await WdaClient().status().ready) == true {
                    statusMessage = "WDA listo en este iPhone (\(launchedBundle)). Ya puedes volver a encender Tailscale si usas sandbox."
                    return
                }
            }
            statusMessage = "App lanzada (\(launchedBundle)), pero WDA aún no responde en :8100. Si sigue igual, arráncalo una vez desde la PC."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Takes a direct CoreDevice/DVT screenshot over the loopback VPN without needing WDA.
    public func testScreenshotOverLoopback() async {
        refreshState()
        errorMessage = nil
        statusMessage = nil
        guard hasPairingFile else {
            errorMessage = "Primero importa tu pairingFile.plist."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let pairingPath = pairingFileURL.path
            statusMessage = "Abriendo túnel RemotePairing en 10.7.0.1…"
            let bytes = try await withTimeout(seconds: 15, label: "La captura por túnel tardó demasiado (>15s). Verifica LocalDevVPN y pairingFile.plist.") {
                try await Task.detached(priority: .userInitiated) {
                    try Self.takeScreenshotSync(pairingPath: pairingPath)
                }.value
            }
            statusMessage = "Captura por túnel correcta (\(bytes.count / 1024) KB)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LoopbackError.failed(label)
            }
            guard let first = try await group.next() else {
                throw LoopbackError.failed(label)
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Network interface probe

    private nonisolated static func activeTunnelIPv4Addresses() -> [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                addrs.append(String(cString: hostname))
            }
        }
        return addrs
    }

    // MARK: - idevice FFI bridge

    private nonisolated static func launchWDASync(pairingPath: String) throws -> String {
        #if canImport(idevice)
        let conn = try openRSDConnection(pairingPath: pairingPath)
        defer { conn.close() }

        var appService: OpaquePointer?
        try checkIdevice(app_service_connect_rsd(conn.adapter, conn.handshake, &appService))
        guard let appService else { throw LoopbackError.failed("No se pudo abrir AppService.") }
        defer { app_service_free(appService) }

        var appsPtr: UnsafeMutablePointer<AppListEntryC>?
        var count: UInt = 0
        try checkIdevice(app_service_list_apps(appService, 0, 1, 1, 0, 0, &appsPtr, &count))
        defer {
            if let appsPtr { app_service_free_app_list(appsPtr, count) }
        }

        var wdaBundle: String?
        if let appsPtr {
            for i in 0..<Int(count) {
                if let cBundle = appsPtr[i].bundle_identifier {
                    let bundle = String(cString: cBundle)
                    if bundle.localizedCaseInsensitiveContains("WebDriverAgentRunner") {
                        wdaBundle = bundle
                        break
                    }
                }
            }
        }
        guard let targetBundle = wdaBundle else {
            throw LoopbackError.failed("No se encontró WebDriverAgentRunner instalado en este iPhone.")
        }

        var response: UnsafeMutablePointer<LaunchResponseC>?
        try targetBundle.withCString { cBundle in
            try checkIdevice(app_service_launch_app(appService, cBundle, nil, 0, 0, 0, nil, &response))
        }
        if let response { app_service_free_launch_response(response) }
        return targetBundle
        #else
        throw LoopbackError.failed("Esta compilación no incluye idevice.")
        #endif
    }

    private nonisolated static func takeScreenshotSync(pairingPath: String) throws -> Data {
        #if canImport(idevice)
        let conn = try openRSDConnection(pairingPath: pairingPath)
        defer { conn.close() }

        var server: OpaquePointer?
        try checkIdevice(remote_server_connect_rsd(conn.adapter, conn.handshake, &server))
        guard let server else { throw LoopbackError.failed("No se pudo abrir RemoteServer.") }
        defer { remote_server_free(server) }

        var client: OpaquePointer?
        try checkIdevice(screenshot_client_new(server, &client))
        guard let client else { throw LoopbackError.failed("No se pudo abrir ScreenshotClient.") }
        defer { screenshot_client_free(client) }

        var rawPtr: UnsafeMutablePointer<UInt8>?
        var rawLen: UInt = 0
        try checkIdevice(screenshot_client_take_screenshot(client, &rawPtr, &rawLen))
        guard let rawPtr, rawLen > 0 else {
            throw LoopbackError.failed("Captura vacía.")
        }
        defer { idevice_data_free(rawPtr, rawLen) }
        return Data(bytes: rawPtr, count: Int(rawLen))
        #else
        throw LoopbackError.failed("Esta compilación no incluye idevice.")
        #endif
    }

    #if canImport(idevice)
    private struct RSDConnection {
        let adapter: OpaquePointer
        let handshake: OpaquePointer

        func close() {
            rsd_handshake_free(handshake)
            adapter_free(adapter)
        }
    }

    private nonisolated static func openRSDConnection(pairingPath: String) throws -> RSDConnection {
        var pairing: OpaquePointer?
        try pairingPath.withCString { cPath in
            try checkIdevice(rp_pairing_file_read(cPath, &pairing))
        }
        guard let pairing else { throw LoopbackError.failed("pairingFile.plist no válido (debe ser formato RemotePairing).") }
        defer { rp_pairing_file_free(pairing) }

        let port = RemotePairingBonjourResolver.resolvePort(timeout: 3)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        inet_pton(AF_INET, "10.7.0.1", &addr.sin_addr)

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        try "iSyCodeMovil".withCString { hostPtr in
            try withUnsafePointer(to: &addr) { addrPtr in
                try addrPtr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sockPtr in
                    try checkIdevice(tunnel_create_rppairing(
                        sockPtr,
                        idevice_socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostPtr,
                        pairing,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    ))
                }
            }
        }
        guard let adapter, let handshake else {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
            throw LoopbackError.failed("No se pudo abrir el túnel RemotePairing en 10.7.0.1:\(port).")
        }
        return RSDConnection(adapter: adapter, handshake: handshake)
    }

    private nonisolated static func checkIdevice(_ err: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let err else { return }
        let msg = err.pointee.message.map { String(cString: $0) } ?? "Error idevice (\(err.pointee.code))"
        idevice_error_free(err)
        throw LoopbackError.failed(msg)
    }
    #endif
}

private final class RemotePairingBonjourResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolvedPort: UInt16?

    static func resolvePort(timeout: TimeInterval = 3) -> UInt16 {
        let resolver = RemotePairingBonjourResolver()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            resolver.search(timeout: timeout)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return resolver.resolvedPort ?? 49152
    }

    private func search(timeout: TimeInterval) {
        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        let deadline = Date().addingTimeInterval(timeout)
        while resolvedPort == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        browser.stop()
        services.forEach { $0.stop() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if (1...65535).contains(sender.port), resolvedPort == nil {
            resolvedPort = UInt16(sender.port)
        }
    }
}

private enum LoopbackError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let msg): return msg
        }
    }
}
