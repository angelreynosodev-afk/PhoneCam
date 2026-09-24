import AVFoundation

enum VideoMode: String, CaseIterable, Identifiable {
    case p720_30, p720_60, p1080_30, p1080_60, p2160_30

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .p720_30, .p720_60: return 1280
        case .p1080_30, .p1080_60: return 1920
        case .p2160_30: return 3840
        }
    }

    var height: Int32 {
        switch self {
        case .p720_30, .p720_60: return 720
        case .p1080_30, .p1080_60: return 1080
        case .p2160_30: return 2160
        }
    }

    var fps: Int32 {
        switch self {
        case .p720_60, .p1080_60: return 60
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
        }
    }

    var label: String {
        switch self {
        case .p720_30: return "720p · 30 fps"
        case .p720_60: return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        case .p2160_30: return "4K · 30 fps"
        }
    }
}

enum Lens: String, CaseIterable, Identifiable {
    case wide, tele, front

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: return "Normal"
        case .tele: return "Tele 2x"
        case .front: return "Frontal"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        self == .tele ? .builtInTelephotoCamera : .builtInWideAngleCamera
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }
}
