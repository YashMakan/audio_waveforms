import AVFoundation
import AVFAudio
import Accelerate

public class AudioRecorder: NSObject, AVAudioRecorderDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Old API – keep for compatibility, but no longer used for recording
    var audioRecorder: AVAudioRecorder?

    // File / state
    var path: String?
    var useLegacyNormalization: Bool = false
    var audioUrl: URL?
    var recordedDuration: CMTime = .zero

    // Flutter plumbing
    var flutterChannel: FlutterMethodChannel
    var bytesStreamEngine: RecorderBytesStreamEngine

    // New low-level capture/encoding stack
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var captureQueue = DispatchQueue(label: "audio_capture_queue")

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?

    // Recording state
    private var isRecording = false
    private var isPaused = false
    private var didStartSession = false

    // Timing for correct duration (handles pause/resume)
    private var sessionStartTime: CMTime?
    private var currentSegmentStartTime: CMTime?
    private var lastSampleTime: CMTime?
    private var accumulatedRecordedTime: CMTime = .zero

    // For decibel metering
    private var latestPowerDB: Float = -160.0
    private var meterQueue = DispatchQueue(label: "audio_meter_queue")

    // To know if we should deactivate audio session on stop
    private var didOverrideAudioSession = false

    init(channel: FlutterMethodChannel){
        flutterChannel = channel
        bytesStreamEngine = RecorderBytesStreamEngine(channel: channel)
    }

    // MARK: - Public API (same signature)

    func startRecording(_ result: @escaping FlutterResult,_ recordingSettings: RecordingSettings){
        useLegacyNormalization = recordingSettings.useLegacy ?? false
        didOverrideAudioSession = recordingSettings.overrideAudioSession

        // Build audio settings (same as before, reused for AVAssetWriter)
        var settings: [String: Any] = [
            AVFormatIDKey: getEncoder(recordingSettings.encoder ?? 0),
            AVSampleRateKey: recordingSettings.sampleRate ?? 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        if let bitRate = recordingSettings.bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        }

        if (recordingSettings.encoder ?? 0) == Constants.kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = recordingSettings.linearPCMBitDepth
            settings[AVLinearPCMIsBigEndianKey] = recordingSettings.linearPCMIsBigEndian
            settings[AVLinearPCMIsFloatKey] = recordingSettings.linearPCMIsFloat
        }

        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

        // Resolve path as before
        if recordingSettings.path == nil {
            let documentDirectory = getDocumentDirectory(result)
            let date = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = recordingSettings.fileNameFormat
            let fileName = dateFormatter.string(from: date) + ".m4a"
            self.path = "\(documentDirectory)/\(fileName)"
        } else {
            self.path = recordingSettings.path
        }

        guard let path = self.path else {
            result(FlutterError(code: Constants.audioWaveforms, message: "Invalid file path", details: nil))
            return
        }

        do {
            // Configure AVAudioSession (no voiceChat mode!)
            if recordingSettings.overrideAudioSession {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
            }

            // Prepare URL and remove any existing file
            audioUrl = URL(fileURLWithPath: path)
            if let url = audioUrl, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }

            guard let audioUrl = audioUrl else {
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to initialise file URL", details: nil))
                return
            }

            // Build capture session
            let captureSession = AVCaptureSession()
            self.captureSession = captureSession

            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                result(FlutterError(code: Constants.audioWaveforms, message: "No audio capture device available", details: nil))
                return
            }

            // ✅ Apply Voice Isolation (if supported)
            if #available(iOS 17.0, *) {
                if audioDevice.isMicrophoneModeSupported(.voiceIsolation) {
                    do {
                        try audioDevice.lockForConfiguration()
                        audioDevice.microphoneMode = .voiceIsolation
                        audioDevice.unlockForConfiguration()
                    } catch {
                        print("Failed to set microphone mode: \(error)")
                    }
                }
            }

            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            } else {
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to add audio input to capture session", details: nil))
                return
            }

            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            } else {
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to add audio output to capture session", details: nil))
                return
            }
            self.audioOutput = audioOutput

            // Prepare AVAssetWriter
            let writer = try AVAssetWriter(outputURL: audioUrl, fileType: .m4a)
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            writerInput.expectsMediaDataInRealTime = true

            if writer.canAdd(writerInput) {
                writer.add(writerInput)
            } else {
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to add audio input to AVAssetWriter", details: nil))
                return
            }

            self.assetWriter = writer
            self.assetWriterInput = writerInput

            // Reset timing state
            self.sessionStartTime = nil
            self.currentSegmentStartTime = nil
            self.lastSampleTime = nil
            self.accumulatedRecordedTime = .zero
            self.isPaused = false
            self.isRecording = true
            self.didStartSession = false

            // Start writer and session
            writer.startWriting()
            captureSession.startRunning()

            bytesStreamEngine.attach()
            result(true)

        } catch {
            result(FlutterError(code: Constants.audioWaveforms, message: "Failed to start recording", details: error.localizedDescription))
        }
    }

    public func stopRecording(_ result: @escaping FlutterResult) {
        guard isRecording else {
            sendResult(result, duration: 0)
            return
        }

        isRecording = false

        // Stop capture session
        captureSession?.stopRunning()
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)

        bytesStreamEngine.detach()

        // Finalise timing (handle last open segment if not paused)
        meterQueue.sync {
            if let start = self.currentSegmentStartTime, let end = self.lastSampleTime {
                let segment = CMTimeSubtract(end, start)
                self.accumulatedRecordedTime = CMTimeAdd(self.accumulatedRecordedTime, segment)
                self.currentSegmentStartTime = nil
            }
        }

        // Finish writing
        assetWriterInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            guard let self = self else { return }

            if self.didOverrideAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false)
            }

            // Compute final duration in ms
            let totalTime = self.accumulatedRecordedTime
            let seconds = CMTimeGetSeconds(totalTime)
            let durationMs = seconds.isFinite ? Int(seconds * 1000) : 0

            self.assetWriter = nil
            self.assetWriterInput = nil
            self.captureSession = nil
            self.audioOutput = nil

            if self.path != nil {
                self.sendResult(result, duration: durationMs)
            } else {
                self.sendResult(result, duration: 0)
            }
        }
    }

    private func sendResult(_ result: @escaping FlutterResult, duration:Int){
        var params = [String:Any?]()
        params[Constants.resultFilePath] = path
        params[Constants.resultDuration] = duration
        result(params)
    }

    public func pauseRecording(_ result: @escaping FlutterResult) {
        guard isRecording else {
            result(false)
            return
        }

        meterQueue.sync {
            if !self.isPaused, let start = self.currentSegmentStartTime, let end = self.lastSampleTime {
                let segment = CMTimeSubtract(end, start)
                self.accumulatedRecordedTime = CMTimeAdd(self.accumulatedRecordedTime, segment)
                self.currentSegmentStartTime = nil
            }
            self.isPaused = true
        }

        result(false)
    }

    public func resumeRecording(_ result: @escaping FlutterResult) {
        guard isRecording else {
            result(false)
            return
        }

        meterQueue.sync {
            self.isPaused = false
            // currentSegmentStartTime will be set on next buffer append
        }

        result(true)
    }

    public func getDecibel(_ result: @escaping FlutterResult) {
        meterQueue.async {
            let amp = self.latestPowerDB
            if self.useLegacyNormalization {
                result(amp)
            } else {
                let linear = pow(10.0, amp / 20.0)
                result(linear)
            }
        }
    }

    public func checkHasPermission(_ result: @escaping FlutterResult){
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission() { allowed in
                DispatchQueue.main.async {
                    result(allowed)
                }
            }
        case .denied:
            result(false)
        case .granted:
            result(true)
        @unknown default:
            result(false)
        }
    }

    public func getEncoder(_ enCoder: Int) -> Int {
        switch(enCoder) {
        case Constants.kAudioFormatMPEG4AAC:
            return Int(kAudioFormatMPEG4AAC)
        case Constants.kAudioFormatMPEGLayer1:
            return Int(kAudioFormatMPEGLayer1)
        case Constants.kAudioFormatMPEGLayer2:
            return Int(kAudioFormatMPEGLayer2)
        case Constants.kAudioFormatMPEGLayer3:
            return Int(kAudioFormatMPEGLayer3)
        case Constants.kAudioFormatMPEG4AAC_ELD:
            return Int(kAudioFormatMPEG4AAC_ELD)
        case Constants.kAudioFormatMPEG4AAC_HE:
            return Int(kAudioFormatMPEG4AAC_HE)
        case Constants.kAudioFormatOpus:
            return Int(kAudioFormatOpus)
        case Constants.kAudioFormatAMR:
            return Int(kAudioFormatAMR)
        case Constants.kAudioFormatAMR_WB:
            return Int(kAudioFormatAMR_WB)
        case Constants.kAudioFormatLinearPCM:
            return Int(kAudioFormatLinearPCM)
        case Constants.kAudioFormatAppleLossless:
            return Int(kAudioFormatAppleLossless)
        case Constants.kAudioFormatMPEG4AAC_HE_V2:
            return Int(kAudioFormatMPEG4AAC_HE_V2)
        default:
            return Int(kAudioFormatMPEG4AAC)
        }
    }

    private func getDocumentDirectory(_ result: @escaping FlutterResult) -> String {
        let directory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let ifExists = FileManager.default.fileExists(atPath: directory)
        if directory.isEmpty {
            result(FlutterError(code: Constants.audioWaveforms, message: "The document directory path is empty", details: nil))
            return ""
        } else if !ifExists {
            result(FlutterError(code: Constants.audioWaveforms, message: "The document directory does't exists", details: nil))
            return ""
        }
        return directory
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

        guard isRecording, let writer = assetWriter, let writerInput = assetWriterInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Start session on first buffer
        if !didStartSession {
            writer.startSession(atSourceTime: pts)
            sessionStartTime = pts
            didStartSession = true
        }

        // Handle pause: only append when not paused
        meterQueue.sync {
            if self.isPaused {
                // Still update meters from paused audio so UI can show live level
                self.updateMeters(from: sampleBuffer)
                return
            }

            // Track current recording segment
            if self.currentSegmentStartTime == nil {
                self.currentSegmentStartTime = pts
            }
            self.lastSampleTime = pts

            // Update meters
            self.updateMeters(from: sampleBuffer)

            // Append to writer
            if writer.status == .unknown {
                return
            }
            if writer.status == .failed {
                print("AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown error")")
                return
            }

            if writerInput.isReadyForMoreMediaData {
                writerInput.append(sampleBuffer)
            }
        }
    }

    // MARK: - Metering

    private func updateMeters(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let dataPointerUnwrapped = dataPointer, totalLength > 0 else {
            return
        }

        // Assume 16-bit PCM for simplicity
        let sampleCount = totalLength / MemoryLayout<Int16>.size
        if sampleCount == 0 { return }

        dataPointerUnwrapped.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samplesPtr in
            var sum: Float = 0.0
            for i in 0..<sampleCount {
                let s = Float(samplesPtr[i]) / Float(Int16(Int16.max))
                sum += s * s
            }
            let rms = sqrt(sum / Float(sampleCount))
            if rms > 0 {
                let db = 20.0 * log10f(rms)
                self.latestPowerDB = db
            } else {
                self.latestPowerDB = -160.0
            }
        }
    }
}
