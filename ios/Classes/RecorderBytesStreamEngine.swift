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

            var rms: Float = 0.0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

            // --- FIX STARTS HERE ---

            // 1. Define a gain factor to amplify the raw RMS value.
            //    You can experiment with this value. 70.0 is a good starting point.
            let gain: Float = 70.0

            // 2. Apply the gain and clamp the result to a maximum of 1.0.
            let scaledRms = min(1.0, rms * gain)

            // --- FIX ENDS HERE ---

            if let convertedBytes = self.convertToFlutterType(buffer) {
                // 3. Send the new 'scaledRms' value to Flutter.
                self.sendToFlutter(rms: scaledRms, bytes: convertedBytes)
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