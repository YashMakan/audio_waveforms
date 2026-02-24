import AVFoundation
import Accelerate
import Speech

public class AudioRecorder: NSObject, AVAudioRecorderDelegate, SFSpeechRecognizerDelegate {
    var audioRecorder: AVAudioRecorder?
    var path: String?
    var useLegacyNormalization: Bool = false
    var audioUrl: URL?
    var recordedDuration: CMTime = CMTime.zero
    var flutterChannel: FlutterMethodChannel
    var bytesStreamEngine: RecorderBytesStreamEngine

    // Speech Recognition properties
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var enableSpeechToText: Bool = false
    private var enableVoiceProcessing: Bool = false
    private var transcriptWords: [[String: Any]] = []
    private var fullTranscript: String = ""

    init(channel: FlutterMethodChannel){
        flutterChannel = channel
        bytesStreamEngine = RecorderBytesStreamEngine(channel: channel)
        super.init()

        // Initialize speech recognizer
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
    }

    func checkSpeechPermission(_ result: @escaping FlutterResult) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    result(true)
                case .denied, .restricted, .notDetermined:
                    result(false)
                @unknown default:
                    result(false)
                }
            }
        }
    }

    func startRecording(_ result: @escaping FlutterResult, _ recordingSettings: RecordingSettings) {
        useLegacyNormalization = recordingSettings.useLegacy ?? false
        enableSpeechToText = recordingSettings.enableSpeechToText ?? false
        enableVoiceProcessing = recordingSettings.enableVoiceProcessing ?? false

        var settings: [String: Any] = [
            AVFormatIDKey: getEncoder(recordingSettings.encoder ?? 0),
            AVSampleRateKey: recordingSettings.sampleRate ?? 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        if (recordingSettings.bitRate != nil) {
            settings[AVEncoderBitRateKey] = recordingSettings.bitRate
        }

        if ((recordingSettings.encoder ?? 0) == Constants.kAudioFormatLinearPCM) {
            settings[AVLinearPCMBitDepthKey] = recordingSettings.linearPCMBitDepth
            settings[AVLinearPCMIsBigEndianKey] = recordingSettings.linearPCMIsBigEndian
            settings[AVLinearPCMIsFloatKey] = recordingSettings.linearPCMIsFloat
        }

        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

        if (recordingSettings.path == nil) {
            let documentDirectory = getDocumentDirectory(result)
            let date = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = recordingSettings.fileNameFormat
            let fileName = dateFormatter.string(from: date) + ".m4a"
            self.path = "\(documentDirectory)/\(fileName)"
        } else {
            self.path = recordingSettings.path
        }

        do {
            if recordingSettings.overrideAudioSession {
                // Use .voiceChat mode if voice processing is enabled so AVAudioRecorder file captures reduced noise.
                let mode: AVAudioSession.Mode = enableVoiceProcessing ? .voiceChat : .default
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: mode, options: options)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            audioUrl = URL(fileURLWithPath: self.path!)

            if(audioUrl == nil){
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to initialise file URL", details: nil))
                return
            }
            audioRecorder = try AVAudioRecorder(url: audioUrl!, settings: settings as [String : Any])

            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()

            // NEW: Receive buffers seamlessly from the bytes stream engine
            bytesStreamEngine.onBufferAvailable = { [weak self] buffer in
                guard let self = self else { return }
                if self.enableSpeechToText {
                    self.recognitionRequest?.append(buffer)
                }
            }

            // Attach stream engine
            bytesStreamEngine.attach(result: result, enableVoiceProcessing: enableVoiceProcessing)

            // Start speech recognition if enabled
            if enableSpeechToText {
                startSpeechRecognition()
            }

            result(true)
        } catch {
            result(FlutterError(code: Constants.audioWaveforms, message: "Failed to start recording", details: error.localizedDescription))
        }
    }

    private func startSpeechRecognition() {
        // Reset previous transcription
        transcriptWords.removeAll()
        fullTranscript = ""

        // Cancel previous task if any
        recognitionTask?.cancel()
        recognitionTask = nil

        // Create and configure the speech recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            debugPrint("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true // On-device recognition

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                self.processRecognitionResult(result)
            }

            if error != nil || result?.isFinal == true {
                self.recognitionRequest = nil
                self.recognitionTask = nil
            }
        }
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let bestTranscription = result.bestTranscription
        fullTranscript = bestTranscription.formattedString

        // Extract word-level timing
        transcriptWords.removeAll()
        for segment in bestTranscription.segments {
            let word: [String: Any] = [
                "word": segment.substring,
                "start": segment.timestamp,
                "end": segment.timestamp + segment.duration,
                "confidence": segment.confidence
            ]
            transcriptWords.append(word)
        }

        // Send real-time transcript updates to Flutter
        sendTranscriptUpdate()
    }

    private func sendTranscriptUpdate() {
        let transcriptData: [String: Any] = [
            "full_text": fullTranscript,
            "words": transcriptWords
        ]

        flutterChannel.invokeMethod(Constants.onTranscriptUpdate, arguments: transcriptData)
    }

    public func stopRecording(_ result: @escaping FlutterResult) {
        audioRecorder?.stop()
        bytesStreamEngine.detach()

        // Stop speech recognition
        if enableSpeechToText {
            stopSpeechRecognition()
        }

        if(audioUrl != nil) {
            let asset = AVURLAsset(url: audioUrl!)

            if #available(iOS 15.0, *) {
                Task {
                    do {
                        recordedDuration = try await asset.load(.duration)
                        sendResult(result, duration: Int(recordedDuration.seconds * 1000))
                    } catch let err {
                        debugPrint(err.localizedDescription)
                        sendResult(result, duration: Int(CMTime.zero.seconds))
                    }
                }
            } else {
                recordedDuration = asset.duration
                sendResult(result, duration: Int(recordedDuration.seconds * 1000))
            }
        } else {
            sendResult(result, duration: Int(CMTime.zero.seconds))
        }
        audioRecorder = nil
    }

    private func stopSpeechRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
    }

    private func sendResult(_ result: @escaping FlutterResult, duration: Int) {
        var params = [String: Any?]()
        params[Constants.resultFilePath] = path
        params[Constants.resultDuration] = duration

        // Add transcript if speech-to-text was enabled
        if enableSpeechToText {
            let transcriptData: [String: Any] = [
                "full_text": fullTranscript,
                "words": transcriptWords
            ]
            params[Constants.resultTranscript] = transcriptData
        }

        result(params)
    }

    public func pauseRecording(_ result: @escaping FlutterResult) {
        audioRecorder?.pause()
        bytesStreamEngine.togglePause()
        result(false)
    }

    public func resumeRecording(_ result: @escaping FlutterResult) {
        audioRecorder?.record()
        bytesStreamEngine.togglePause()
        result(true)
    }

    public func getDecibel(_ result: @escaping FlutterResult) {
        audioRecorder?.updateMeters()
        if(useLegacyNormalization){
            let amp = audioRecorder?.averagePower(forChannel: 0) ?? 0.0
            result(amp)
        } else {
            let amp = audioRecorder?.peakPower(forChannel: 0) ?? 0.0
            let linear = pow(10, amp / 20);
            result(linear)
        }
    }

    public func checkHasPermission(_ result: @escaping FlutterResult){
        switch AVAudioSession.sharedInstance().recordPermission{
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
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
        if(directory.isEmpty){
            result(FlutterError(code: Constants.audioWaveforms, message: "The document directory path is empty", details: nil))
            return ""
        } else if(!ifExists) {
            result(FlutterError(code: Constants.audioWaveforms, message: "The document directory does't exists", details: nil))
            return ""
        }
        return directory
    }

    // MARK: - SFSpeechRecognizerDelegate
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            debugPrint("Speech recognition not available")
        }
    }
}