import Foundation
import Network

/// Servidor TCP: OBS se conecta a tcp://IP:5000 y recibe MPEG-TS.
/// Un solo cliente a la vez; si llega otro, reemplaza al anterior.
/// Todo corre en `queue`.
final class StreamServer {
    let queue = DispatchQueue(label: "net", qos: .userInteractive)
    var onClientChange: ((Bool) -> Void)?
    var onNeedKeyframe: (() -> Void)?

    private let port: UInt16
    private var listener: NWListener?
    private var conn: NWConnection?
    private var pendingBytes = 0
    private var waitKey = true
    /// Si la red no da abasto se descartan frames hasta el siguiente keyframe,
    /// en lugar de acumular retraso.
    private let maxPending = 2_000_000

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
        onNeedKeyframe?()
    }

    /// Solo sirve para detectar cuando OBS cierra la conexión.
    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil {
                c.cancel()
                return
            }
            self?.receiveLoop(c)
        }
    }

    private func drop(_ c: NWConnection) {
        guard conn === c else { return }
        conn = nil
        onClientChange?(false)
    }

    /// Decide si este frame se envía. Se consulta antes de muxear.
    func wants(isKey: Bool) -> Bool {
        guard conn != nil else { return false }
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
