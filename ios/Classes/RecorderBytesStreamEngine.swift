import Foundation
import AVFAudio
import Accelerate

class RecorderBytesStreamEngine {
    private var audioEngine = AVAudioEngine()
    private var audioFormat: AVAudioFormat?
    private var flutterChannel: FlutterMethodChannel

    init(channel: FlutterMethodChannel) {
        flutterChannel = channel
    }

    func attach() {
        let inputNode = audioEngine.inputNode
        audioFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: audioFormat) { (buffer, time) in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // 1. Calculate the raw RMS (linear amplitude)
            var rms: Float = 0.0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

            // --- NEW LOGARITHMIC SCALING LOGIC ---

            // 2. Define a lower bound for silence in decibels.
            //    -50.0 dB is a good value for quiet environments. You can adjust this.
            let dbReference: Float = -50.0

            // 3. Convert the linear RMS to a decibel scale.
            //    We use a small epsilon (1e-5) to prevent log(0) which is -infinity.
            let dbValue = 20 * log10f(rms + 1e-5)

            // 4. Normalize the decibel value to a 0.0 to 1.0 range.
            //    This maps our `dbReference` to 0.0 and 0 dB (max level) to 1.0.
            let normalizedLevel = (dbValue - dbReference) / -dbReference

            // 5. Clamp the final value to ensure it's always between 0.0 and 1.0.
            let finalLevel = max(0.0, min(1.0, normalizedLevel))

            // --- END OF NEW LOGIC ---

            if let convertedBytes = self.convertToFlutterType(buffer) {
                // 6. Send the final, naturally-scaled level to Flutter.
                self.sendToFlutter(rms: finalLevel, bytes: convertedBytes)
            }
        }
        do {
            try audioEngine.start()
        } catch {
              print("AudioWaveforms: Error starting Audio Engine - \(error.localizedDescription)")
          }
    }

    func detach() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func convertToFlutterType(_ buffer: AVAudioPCMBuffer) -> FlutterStandardTypedData? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameLength = Int(buffer.frameLength)

        var audioSamples = [Float32](repeating: 0.0, count: frameLength)
        for i in 0..<frameLength {
            audioSamples[i] = channelData[i]
        }

        let byteCount = frameLength * MemoryLayout<Float32>.size
        let byteBuffer = audioSamples.withUnsafeBufferPointer { bufferPointer in
            return Data(buffer: bufferPointer)
        }
        let convertedBuffer = FlutterStandardTypedData(bytes: byteBuffer)
        return convertedBuffer
    }

    private func sendToFlutter(rms: Float, bytes: FlutterStandardTypedData) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            flutterChannel.invokeMethod(Constants.onAudioChunk, arguments: [
                Constants.bytes: bytes,
                Constants.normalisedRms: rms
            ])
        }
    }
}