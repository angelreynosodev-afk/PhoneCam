import AVFoundation
import Foundation

enum VideoMode: String, CaseIterable, Identifiable {
    case p720_30, p720_60, p1080_30, p1080_60, p2160_30, p2160_60

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .p720_30, .p720_60: return 1280
        case .p1080_30, .p1080_60: return 1920
        case .p2160_30, .p2160_60: return 3840
        }
    }

    var height: Int32 {
        switch self {
        case .p720_30, .p720_60: return 720
        case .p1080_30, .p1080_60: return 1080
        case .p2160_30, .p2160_60: return 2160
        }
    }

    var fps: Int32 {
        switch self {
        case .p720_60, .p1080_60, .p2160_60: return 60
        default: return 30
        }
    }

    /// Bits por segundo. De sobra para Wi-Fi local o USB.
    var bitrate: Int {
        switch self {
        case .p720_30: return 4_000_000
        case .p720_60: return 6_000_000
        case .p1080_30: return 8_000_000
        case .p1080_60: return 12_000_000
        case .p2160_30: return 25_000_000
        case .p2160_60: return 40_000_000
        }
    }

    var label: String {
        switch self {
        case .p720_30: return "720p · 30 fps"
        case .p720_60: return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        case .p2160_30: return "4K · 30 fps"
        case .p2160_60: return "4K · 60 fps"
        }
    }
}

enum Lens: String, CaseIterable, Identifiable {
    case ultra, wide, tele, front

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultra: return .builtInUltraWideCamera
        case .tele: return .builtInTelephotoCamera
        case .wide, .front: return .builtInWideAngleCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }

    var device: AVCaptureDevice? {
        AVCaptureDevice.default(deviceType, for: .video, position: position)
    }

    /// Lentes que tiene este iPhone, con su etiqueta ("0.5x", "1x", "4x", "Frontal").
    /// El aumento se calcula comparando el campo de visión con el del lente normal,
    /// así sirve igual para un 7 Plus (tele 2x) que para un 17 Pro (tele 4x).
    static func available() -> [LensOption] {
        let wideFov = Lens.wide.device?.activeFormat.videoFieldOfView ?? 0
        return allCases.compactMap { lens in
            guard let dev = lens.device else { return nil }
            if lens == .front { return LensOption(lens: lens, label: "Frontal") }
            if lens == .wide || wideFov <= 0 { return LensOption(lens: lens, label: "1x") }
            let fov = dev.activeFormat.videoFieldOfView
            let factor = tan(Double(wideFov) * .pi / 360) / tan(Double(fov) * .pi / 360)
            let text = factor < 1 ? String(format: "%.1fx", factor) : "\(Int(factor.rounded()))x"
            return LensOption(lens: lens, label: text)
        }
    }
}

struct LensOption: Identifiable {
    let lens: Lens
    let label: String
    var id: Lens { lens }
}
