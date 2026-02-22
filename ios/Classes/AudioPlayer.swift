import Foundation
import AVKit

class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var seekToStart = true
    private var stopWhenCompleted = false
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var finishMode:FinishMode = FinishMode.stop
    private var updateFrequency = 200
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel

    // Store session configuration to apply on play
    private var shouldOverrideSession: Bool = false
    private var audioOutputType: Int = 0

    init(plugin: SwiftAudioWaveformsPlugin, playerKey: String, channel: FlutterMethodChannel) {
        self.plugin = plugin
        self.playerKey = playerKey
        flutterChannel = channel
    }

    func preparePlayer(path: String?, volume: Double?, updateFrequency: Int?, result: @escaping FlutterResult, overrideAudioSession : Bool, audioOutput: Int?) {
        if(!(path ?? "").isEmpty) {
            self.updateFrequency = updateFrequency ?? 200

            // Store configuration for later use in startPlyer
            self.shouldOverrideSession = overrideAudioSession
            self.audioOutputType = audioOutput ?? 0

            let audioUrl = URL.init(string: path!)
            if(audioUrl == nil){
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to initialise Url from provided audio file", details: "If path contains `file://` try removing it"))
                return
            }

            do {
                // STOP PREVIOUS PLAYER
                stopPlayer()
                player = nil

                // INITIALIZE PLAYER
                // We do NOT set the category here anymore to prevent hijacking audio on list render.
                player = try AVAudioPlayer(contentsOf: audioUrl!)

                player?.enableRate = true
                player?.rate = 1.0
                player?.volume = Float(volume ?? 1.0)
                player?.prepareToPlay()

                result(true)

            } catch {
                result(FlutterError(code: Constants.audioWaveforms, message: "Failed to prepare player", details: error.localizedDescription))
                return
            }
        } else {
            result(FlutterError(code: Constants.audioWaveforms, message: "Audio file path can't be empty or null", details: nil))
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) {
        var finishType = 2

        switch self.finishMode{

        case .loop:
            self.player?.currentTime = 0
            self.player?.play()
            finishType = 0

        case .pause:
            self.player?.pause()
            stopListening()
            finishType = 1

        case .stop:
            self.player?.stop()
            stopListening()
            self.player = nil
            finishType = 2
        }

        plugin.flutterChannel.invokeMethod(Constants.onDidFinishPlayingAudio, arguments: [
            Constants.finishType: finishType,
            Constants.playerKey: playerKey])

    }

    func startPlyer(result: @escaping FlutterResult) {
        // APPLY SESSION CONFIGURATION HERE (Just-in-time)
        if self.shouldOverrideSession {
            do {
                let session = AVAudioSession.sharedInstance()

                if self.audioOutputType == 1 {
                    // EARPIECE MODE
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                } else {
                    // SPEAKER MODE
                    try session.setCategory(.playback, mode: .default, options: .defaultToSpeaker)
                }

                try session.setActive(true)
            } catch {
                print("AudioWaveforms: Failed to set audio session category: \(error)")
            }
        }

        player?.play()
        player?.delegate = self
        startListening()
        result(true)
    }


    func pausePlayer() {
        stopListening()
        player?.pause()
    }
    
    func stopPlayer() {
        stopListening()
        player?.stop()
        timer = nil
    }
    
    func release(result: @escaping FlutterResult) {
        player = nil
        result(true)
    }
    
    func getDuration(_ type: DurationType, _ result: @escaping FlutterResult) throws {
        if type == .Current {
            let ms = (player?.currentTime ?? 0) * 1000
            result(Int(ms))
        } else {
            let ms = (player?.duration ?? 0) * 1000
            result(Int(ms))
        }
    }
    
    func setVolume(_ volume: Double?, _ result: @escaping FlutterResult) {
        player?.volume = Float(volume ?? 1.0)
        result(true)
    }

    func setRate(_ rate: Double?, _ result: @escaping FlutterResult) {
        player?.rate = Float(rate ?? 1.0);
        result(true)
    }

    func seekTo(_ time: Int?, _ result: @escaping FlutterResult) {
        if(time != nil) {
            player?.currentTime = Double(time! / 1000)
            sendCurrentDuration()
            result(true)
        } else {
            result(false)
        }
    }
    
    func setFinishMode(result : @escaping FlutterResult, releaseType : Int?){
        if(releaseType != nil && releaseType == 0){
            self.finishMode = FinishMode.loop
        }else if(releaseType != nil && releaseType == 1){
            self.finishMode = FinishMode.pause
        }else{
            self.finishMode = FinishMode.stop
        }
        result(nil)
    }

    func startListening() {
        if #available(iOS 10.0, *) {
            timer = Timer.scheduledTimer(withTimeInterval: (Double(updateFrequency) / 1000), repeats: true, block: { _ in
                self.sendCurrentDuration()
            })
        } else {
            // Fallback on earlier versions
        }
    }
    
    func stopListening() {
        timer?.invalidate()
        timer = nil
        sendCurrentDuration()
    }

    func sendCurrentDuration() {
        let ms = (player?.currentTime ?? 0) * 1000
        flutterChannel.invokeMethod(Constants.onCurrentDuration, arguments: [Constants.current: Int(ms), Constants.playerKey: playerKey])
    }
}
