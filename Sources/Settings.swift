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
    /// Aumento de este lente respecto del normal (p. ej. 0.5 el ultra, 4 el tele de un 17 Pro).
    var factor: Double? {
        guard let dev = device, let wide = Lens.wide.device else { return nil }
        if self == .wide { return 1 }
        let w = Double(wide.activeFormat.videoFieldOfView), f = Double(dev.activeFormat.videoFieldOfView)
        guard w > 0, f > 0 else { return nil }
        return tan(w * .pi / 360) / tan(f * .pi / 360)
    }

    /// Botones de lente para este iPhone: "0.5x", "1x", "2x", "4x", "Frontal".
    /// Si el tele es de 3x o más (iPhones nuevos), se agrega un 2x que recorta el sensor
    /// principal, igual que la app Cámara. En un 7 Plus el tele ya es 2x y no hace falta.
    static func available() -> [LensOption] {
        var options: [LensOption] = []
        for lens in allCases {
            guard lens.device != nil else { continue }
            switch lens {
            case .front:
                options.append(LensOption(lens: lens, zoom: 1, label: "Frontal"))
            case .wide:
                options.append(LensOption(lens: lens, zoom: 1, label: "1x"))
                let tele = Lens.tele.factor ?? 0
                if tele < 1.5 || tele >= 3 {
                    options.append(LensOption(lens: .wide, zoom: 2, label: "2x"))
                }
            case .ultra, .tele:
                guard let f = lens.factor else { continue }
                let text = f < 1 ? String(format: "%.1fx", f) : "\(Int(f.rounded()))x"
                options.append(LensOption(lens: lens, zoom: 1, label: text))
            }
        }
        return options
    }
}

/// Un botón del selector de lentes: un lente físico más un zoom inicial.
struct LensOption: Identifiable {
    let lens: Lens
    let zoom: CGFloat
    let label: String
    var id: String { "\(lens.rawValue)-\(zoom)" }
}
