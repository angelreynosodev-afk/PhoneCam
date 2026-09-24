import CoreMedia
import Foundation
import Network

/// Servidor TCP en el puerto 5000. Un solo cliente a la vez; si llega otro, reemplaza al anterior.
/// - El plugin de OBS saluda con "PCAM" al conectar y recibe frames H.264 crudos (modo `.raw`).
///   Después manda líneas JSON con ajustes de cámara; el iPhone le responde con su estado.
/// - Cualquier otro cliente (la "Fuente multimedia" de OBS) recibe MPEG-TS (modo `.ts`).
/// Todo corre en `queue`.
final class StreamServer {
    enum Mode { case pending, ts, raw }

    let queue = DispatchQueue(label: "net", qos: .userInteractive)
    var onClientChange: ((Bool) -> Void)?
    var onNeedKeyframe: (() -> Void)?
    /// Ajustes recibidos del plugin (se llama en `queue`).
    var onControl: (([String: Any]) -> Void)?
    /// Se llama en `queue` cuando el plugin termina de identificarse.
    var onPluginReady: (() -> Void)?
    private(set) var mode: Mode = .pending

    private let port: UInt16
    private var listener: NWListener?
    private var conn: NWConnection?
    private var rx = [UInt8]()
    private var pendingBytes = 0
    private var waitKey = true
    /// Si la red no da abasto se descartan frames hasta el siguiente keyframe,
    /// en lugar de acumular retraso.
    private let maxPending = 500_000

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        queue.async { self.startListener() }
    }

    private func startListener() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            retry()
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self else { return }
            if case .failed = state {
                l?.cancel()
                if self.listener === l { self.listener = nil }
                self.retry()
            }
        }
        l.start(queue: queue)
        listener = l
    }

    private func retry() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        mode = .pending
        rx.removeAll()
        pendingBytes = 0
        waitKey = true
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c else { return }
            switch state {
            case .failed, .cancelled: self.drop(c)
            default: break
            }
        }
        c.start(queue: queue)
        receiveLoop(c)
        onClientChange?(true)

        // La Fuente multimedia no manda nada: si no hubo saludo, es MPEG-TS.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak c] in
            guard let self = self, let c = c, self.conn === c, self.mode == .pending else { return }
            self.mode = .ts
            self.onNeedKeyframe?()
        }
    }

    /// Lee lo que manda el cliente: el saludo del plugin, sus ajustes, y el cierre de la conexión.
    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            if let self = self, self.conn === c, let data = data, !data.isEmpty {
                self.rx += data
                self.processLines()
            }
            if done || error != nil {
                c.cancel()
                return
            }
            self?.receiveLoop(c)
        }
    }

    private func processLines() {
        while let nl = rx.firstIndex(of: 0x0A) {
            let line = Array(rx[..<nl])
            rx.removeSubrange(...nl)
            if mode == .pending, line.starts(with: Array("PCAM".utf8)) {
                mode = .raw
                onNeedKeyframe?()
                onPluginReady?()
            } else if mode == .raw,
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                onControl?(obj)
            }
        }
        if rx.count > 65_536 { rx.removeAll() }
    }

    /// Envía el estado de la cámara al plugin (no pasa por el control de congestión del video).
    func sendState(_ state: [String: Any]) {
        guard let c = conn, mode == .raw,
              let json = try? JSONSerialization.data(withJSONObject: state) else { return }
        var out = [UInt8]()
        let n = UInt32(json.count)
        out += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        out += [UInt8](repeating: 0, count: 8)
        out.append(0x80)
        out += json
        c.send(content: Data(out), completion: .contentProcessed { _ in })
    }

    private func drop(_ c: NWConnection) {
        guard conn === c else { return }
        conn = nil
        onClientChange?(false)
    }

    /// Decide si este frame se envía. Se consulta antes de muxear.
    func wants(isKey: Bool) -> Bool {
        guard conn != nil, mode != .pending else { return false }
        if pendingBytes > maxPending {
            if !waitKey {
                waitKey = true
                onNeedKeyframe?()
            }
            return false
        }
        if waitKey {
            guard isKey else { return false }
            waitKey = false
        }
        return true
    }

    func send(_ bytes: [UInt8]) {
        guard let c = conn else { return }
        let n = bytes.count
        pendingBytes += n
        c.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self = self, self.conn === c else { return }
            self.pendingBytes -= n
            if error != nil { c.cancel() }
        })
    }
}

/// Frame para el plugin: [u32 BE largo][u64 BE pts en µs][u8 flags][H.264 Annex B].
func rawFrame(_ es: [UInt8], pts: CMTime, isKey: Bool) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(es.count + 13)
    let n = UInt32(es.count)
    out += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    let us = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
    for shift in stride(from: 56, through: 0, by: -8) {
        out.append(UInt8((us >> UInt64(shift)) & 0xFF))
    }
    out.append(isKey ? 1 : 0)
    out += es
    return out
}

/// IP del iPhone en la red Wi-Fi (interfaz en0).
func wifiIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var result: String?
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              String(cString: ifa.ifa_name) == "en0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            result = String(cString: host)
        }
    }
    return result
}
