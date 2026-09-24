import CoreMedia

/// Muxer MPEG-TS mínimo: un programa con una sola pista de video H.264.
/// Es lo que OBS ("Fuente multimedia", vía FFmpeg) lee de forma nativa.
final class TSMuxer {
    private static let pmtPID: UInt16 = 0x1000
    private static let videoPID: UInt16 = 0x0100

    private var ccPAT: UInt8 = 0
    private var ccPMT: UInt8 = 0
    private var ccVideo: UInt8 = 0
    private var basePTS: CMTime?

    func mux(_ es: [UInt8], pts: CMTime, isKey: Bool) -> [UInt8] {
        if basePTS == nil { basePTS = pts }
        let rel = CMTimeConvertScale(CMTimeSubtract(pts, basePTS!), timescale: 90000, method: .roundHalfAwayFromZero)
        let pts33 = (UInt64(max(0, rel.value)) + 90000) & 0x1_FFFF_FFFF
        let pcr = pts33 > 3000 ? pts33 - 3000 : 0

        var out = [UInt8]()
        out.reserveCapacity((es.count / 176 + 4) * 188)

        if isKey {
            out += psiPacket(pid: 0, cc: &ccPAT, section: [
                0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                0x00, 0x01, 0xF0, 0x00, // programa 1 -> PMT en PID 0x1000
            ])
            out += psiPacket(pid: Self.pmtPID, cc: &ccPMT, section: [
                0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00,
                0xE1, 0x00, // PCR en PID 0x100
                0xF0, 0x00,
                0x1B, 0xE1, 0x00, 0xF0, 0x00, // H.264 en PID 0x100
            ])
        }

        var pes = [UInt8]()
        pes.reserveCapacity(es.count + 14)
        pes += [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x84, 0x80, 0x05]
        pes += [
            UInt8(0x21 | ((pts33 >> 29) & 0x0E)),
            UInt8((pts33 >> 22) & 0xFF),
            UInt8(((pts33 >> 14) & 0xFE) | 1),
            UInt8((pts33 >> 7) & 0xFF),
            UInt8(((pts33 << 1) & 0xFE) | 1),
        ]
        pes += es

        let pcrBytes: [UInt8] = [
            UInt8((pcr >> 25) & 0xFF), UInt8((pcr >> 17) & 0xFF),
            UInt8((pcr >> 9) & 0xFF), UInt8((pcr >> 1) & 0xFF),
            UInt8(((pcr & 1) << 7) | 0x7E), 0x00,
        ]
        let afFlags: UInt8 = 0x10 | (isKey ? 0x40 : 0) // PCR (+ random access)

        var off = 0
        var first = true
        while off < pes.count {
            let remaining = pes.count - off
            var af: [UInt8]? = first ? [afFlags] + pcrBytes : nil
            var payload = 184 - (af.map { $0.count + 1 } ?? 0)
            if remaining < payload {
                // Rellenar el último paquete con stuffing en el adaptation field.
                let stuff = payload - remaining
                if af == nil {
                    af = stuff == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuff - 2)
                } else {
                    af! += [UInt8](repeating: 0xFF, count: stuff)
                }
                payload = remaining
            }

            out.append(0x47)
            out.append((first ? 0x40 : 0x00) | UInt8(Self.videoPID >> 8))
            out.append(UInt8(Self.videoPID & 0xFF))
            out.append((af != nil ? 0x30 : 0x10) | ccVideo)
            ccVideo = (ccVideo + 1) & 0x0F
            if let af = af {
                out.append(UInt8(af.count))
                out += af
            }
            out += pes[off..<(off + payload)]
            off += payload
            first = false
        }
        return out
    }

    private func psiPacket(pid: UInt16, cc: inout UInt8, section: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | cc, 0x00]
        cc = (cc + 1) & 0x0F
        p += section
        let crc = Self.crc32(section)
        p += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        p += [UInt8](repeating: 0xFF, count: 188 - p.count)
        return p
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 {
            c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1
        }
        return c
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)]
        }
        return crc
    }
}
