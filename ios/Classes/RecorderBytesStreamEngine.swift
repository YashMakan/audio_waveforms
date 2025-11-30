//
//  RecorderBytesStreamHandler.swift
//  audio_waveforms
//
//  Created by Ujas Majithiya on 10/04/25.
//

import Foundation
import AVFAudio
import Accelerate // <-- 1. Import the Accelerate framework

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
            // --- 2. CALCULATE RMS (AMPLITUDE) HERE ---
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            var rms: Float = 0.0
            // vDSP_rmsqv calculates the root mean square of a vector, which is a great way to get audio level.
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

            // The rms value is a linear amplitude. It's what the UI needs.
            let linearRms = rms

            // Convert buffer to bytes for the stream
            if let convertedBytes = self.convertToFlutterType(buffer) {
                // --- 3. SEND BOTH RMS AND BYTES ---
                self.sendToFlutter(rms: linearRms, bytes: convertedBytes)
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
        // This function is correct, no changes needed here.
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

    // --- 4. MODIFY THE SEND FUNCTION SIGNATURE AND BODY ---
    private func sendToFlutter(rms: Float, bytes: FlutterStandardTypedData) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Now we send a dictionary containing both values
            flutterChannel.invokeMethod(Constants.onAudioChunk, arguments: [
                Constants.bytes: bytes,
                Constants.normalisedRms: rms
            ])
        }
    }
}