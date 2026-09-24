import AVFoundation
import UIKit

/// Cámara -> encoder H.264 -> MPEG-TS -> TCP.
/// Colas: sessionQueue (configuración), videoQueue (frames + encoder), server.queue (red).
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let port: UInt16 = 5000

    @Published var mode: VideoMode { didSet { save(); reconfigure() } }
    @Published var lens: Lens { didSet { save(); reconfigure() } }
    @Published var zoom: CGFloat = 1 { didSet { applyZoom() } }
    @Published var wbAuto: Bool { didSet { save(); applyWhiteBalance() } }
    @Published var temperature: Float { didSet { save(); applyWhiteBalance() } }
    @Published var aeafLocked = false { didSet { applyLock() } }

    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var wbSupported = true
    @Published private(set) var clientConnected = false
    @Published private(set) var status = "Iniciando…"
    @Published private(set) var address = "…"
    @Published private(set) var configVersion = 0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let videoQueue = DispatchQueue(label: "cam.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?

    private let encoder = H264Encoder()
    private let muxer = TSMuxer()
    private let server = StreamServer(port: CameraController.port)
    private var streaming = false // solo se lee/escribe en videoQueue

    override init() {
        let d = UserDefaults.standard
        _mode = Published(initialValue: VideoMode(rawValue: d.string(forKey: "mode") ?? "") ?? .p1080_30)
        _lens = Published(initialValue: Lens(rawValue: d.string(forKey: "lens") ?? "") ?? .wide)
        _wbAuto = Published(initialValue: d.object(forKey: "wbAuto") as? Bool ?? true)
        _temperature = Published(initialValue: d.object(forKey: "temperature") as? Float ?? 5000)
        super.init()

        encoder.onFrame = { [weak self] bytes, pts, isKey in
            guard let self = self else { return }
            self.server.queue.async {
                guard self.server.wants(isKey: isKey) else { return }
                self.server.send(self.muxer.mux(bytes, pts: pts, isKey: isKey))
            }
        }
        server.onNeedKeyframe = { [weak self] in
            self?.videoQueue.async { self?.encoder.forceKeyframe = true }
        }
        server.onClientChange = { [weak self] connected in
            guard let self = self else { return }
            // Sin cliente no se codifica nada: ahorra batería y calor.
            self.videoQueue.async {
                self.streaming = connected
                if connected { self.encoder.forceKeyframe = true } else { self.encoder.invalidate() }
            }
            DispatchQueue.main.async { self.clientConnected = connected }
        }
    }

    // MARK: - Ciclo de vida

    func start() {
        server.start()
        address = wifiIPAddress() ?? "sin Wi‑Fi"
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Sin permiso de cámara (Ajustes › PhoneCam)" }
                return
            }
            DispatchQueue.main.async { self.reconfigure() }
        }
    }

    func resume() {
        server.start()
        address = wifiIPAddress() ?? "sin Wi‑Fi"
        sessionQueue.async {
            if self.input != nil && !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "mode")
        d.set(lens.rawValue, forKey: "lens")
        d.set(wbAuto, forKey: "wbAuto")
        d.set(temperature, forKey: "temperature")
    }

    // MARK: - Configuración de la cámara

    private func reconfigure() {
        let mode = self.mode, lens = self.lens
        sessionQueue.async { self.configure(mode: mode, lens: lens) }
    }

    private func configure(mode: VideoMode, lens: Lens) {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let old = input {
            session.removeInput(old)
            input = nil
            device = nil
        }
        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position),
              let inp = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(inp) else {
            session.commitConfiguration()
            setStatus("Lente no disponible")
            return
        }
        session.addInput(inp)
        input = inp
        device = dev

        if !session.outputs.contains(output) {
            // 420f es el formato nativo del sensor: el encoder lo toma sin conversiones.
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        var fps = mode.fps
        var note = ""
        let picked = pickFormat(dev, mode)
        if picked == nil {
            note = " (resolución no soportada por este lente)"
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        }

        if (try? dev.lockForConfiguration()) != nil {
            if let (format, maxFps) = picked {
                dev.activeFormat = format
                fps = maxFps
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            }
            dev.videoZoomFactor = 1
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }

        if let c = output.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // la estabilización agrega latencia
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false
            }
        }
        session.commitConfiguration()

        let bitrate = mode.bitrate
        videoQueue.sync { encoder.configure(fps: fps, bitrate: bitrate) }
        if !session.isRunning { session.startRunning() }

        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let maxZ = min(dev.activeFormat.videoMaxZoomFactor, 8)
        let wbOK = dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        DispatchQueue.main.async {
            self.maxZoom = maxZ
            self.wbSupported = wbOK
            self.zoom = 1
            self.aeafLocked = false
            self.applyWhiteBalance()
            self.status = "\(dims.width)×\(dims.height) @ \(fps) fps\(note)"
            self.configVersion += 1
        }
    }

    /// Busca un formato 420f con la resolución pedida. Entre los que alcanzan
    /// los fps pedidos, elige el de menor fps máximo (evita formatos de cámara lenta).
    private func pickFormat(_ dev: AVCaptureDevice, _ mode: VideoMode) -> (AVCaptureDevice.Format, Int32)? {
        let want = Double(mode.fps)
        var best: (format: AVCaptureDevice.Format, maxFps: Double)?
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width == mode.width, d.height == mode.height,
                  CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            else { continue }
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            guard let b = best else { best = (f, maxFps); continue }
            let fOK = maxFps >= want, bOK = b.maxFps >= want
            if (fOK && !bOK) || (fOK && bOK && maxFps < b.maxFps) || (!fOK && !bOK && maxFps > b.maxFps) {
                best = (f, maxFps)
            }
        }
        guard let b = best else { return nil }
        return (b.format, Int32(min(want, b.maxFps)))
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: - Controles

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            body(d)
            d.unlockForConfiguration()
        }
    }

    private func applyZoom() {
        let z = zoom
        withDevice { d in
            d.videoZoomFactor = max(1, min(z, d.activeFormat.videoMaxZoomFactor))
        }
    }

    private func applyWhiteBalance() {
        let auto = wbAuto, temp = temperature
        withDevice { d in
            if auto || !d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else {
                var g = d.deviceWhiteBalanceGains(for: .init(temperature: temp, tint: 0))
                let m = d.maxWhiteBalanceGain
                g.redGain = min(max(g.redGain, 1), m)
                g.greenGain = min(max(g.greenGain, 1), m)
                g.blueGain = min(max(g.blueGain, 1), m)
                d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            }
        }
    }

    private func applyLock() {
        let locked = aeafLocked
        withDevice { d in
            let focus: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            if d.isFocusModeSupported(focus) { d.focusMode = focus }
            let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            if d.isExposureModeSupported(exposure) { d.exposureMode = exposure }
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard streaming else { return }
        encoder.encode(sampleBuffer)
    }
}
