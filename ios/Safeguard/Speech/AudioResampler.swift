import AVFoundation

/// Turns microphone buffers (any format) into 16 kHz mono Int16 samples, the
/// audio format the cloud speech service takes. Used from the audio thread,
/// so it keeps one converter and allocates little.
public final class PCM16Resampler: @unchecked Sendable {
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let lock = NSLock()

    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        lock.lock()
        defer { lock.unlock() }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData, out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
