import VideoToolbox

/// Encoder H.264 por hardware. Entrega cada frame en formato Annex B
/// (con start codes), listo para meter en MPEG-TS.
/// Todos los métodos se llaman desde la cola de video.
final class H264Encoder {
    var onFrame: ((_ annexB: [UInt8], _ pts: CMTime, _ isKey: Bool) -> Void)?
    var forceKeyframe = false

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps: Int32 = 30
    private var bitrate = 8_000_000

    func configure(fps: Int32, bitrate: Int) {
        self.fps = fps
        self.bitrate = bitrate
        invalidate()
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    func encode(_ sample: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        if session == nil || w != width || h != height {
            invalidate()
            create(w, h)
        }
        guard let s = session else { return }

        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pb,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, out in
            guard status == noErr, let out = out else { return }
            self?.handle(out)
        }
    }

    private func create(_ w: Int32, _ h: Int32) {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: w, height: h,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s = s else { return }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(s, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        // Sin B-frames: menos latencia y PTS == DTS.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        // Tope: 1.5x el promedio, en bytes por segundo.
        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bitrate * 3 / 16), NSNumber(value: 1)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(s)

        session = s
        width = w
        height = h
        forceKeyframe = true
    }

    private func handle(_ sample: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return }

        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKey = !notSync
        }

        let len = CMBlockBufferGetDataLength(bb)
        var out = [UInt8]()
        out.reserveCapacity(len + 256)
        out += [0, 0, 0, 1, 0x09, 0xF0] // Access Unit Delimiter

        // En keyframes se repiten SPS/PPS para que OBS pueda engancharse en cualquier momento.
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                    parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let p = p {
                    out += [0, 0, 0, 1]
                    out.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
                }
            }
        }

        // AVCC (prefijo de longitud de 4 bytes) -> Annex B (start codes).
        var data = [UInt8](repeating: 0, count: len)
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &data)
        var i = 0
        while i + 4 <= len {
            let nalLen = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            i += 4
            guard nalLen > 0, i + nalLen <= len else { break }
            out += [0, 0, 0, 1]
            out += data[i..<(i + nalLen)]
            i += nalLen
        }

        onFrame?(out, CMSampleBufferGetPresentationTimeStamp(sample), isKey)
    }
}
