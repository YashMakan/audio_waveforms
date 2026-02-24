import Foundation

struct RecordingSettings {
    var path: String?
    var encoder : Int?
    var sampleRate : Int?
    var bitRate : Int?
    var fileNameFormat : String
    var useLegacy : Bool?
    var overrideAudioSession : Bool
    var linearPCMBitDepth : Int
    var linearPCMIsBigEndian : Bool
    var linearPCMIsFloat : Bool
    var enableSpeechToText: Bool?
    var enableVoiceProcessing: Bool? // NEW

    static func fromJson(_ json: [String: Any]) -> RecordingSettings {
        let path = json[Constants.path] as? String
        let encoder = json[Constants.encoder] as? Int
        let sampleRate = json[Constants.sampleRate] as? Int
        let bitRate = json[Constants.bitRate] as? Int
        let fileNameFormat = Constants.fileNameFormat
        let useLegacy = json[Constants.useLegacyNormalization] as? Bool
        let overrideAudioSession = json[Constants.overrideAudioSession] as? Bool ?? true
        let linearPCMBitDepth = json[Constants.linearPCMBitDepth] as? Int ?? 16
        let linearPCMIsBigEndian = json[Constants.linearPCMIsBigEndian] as? Bool ?? false
        let linearPCMIsFloat = json[Constants.linearPCMIsFloat] as? Bool ?? false
        let enableSpeechToText = json[Constants.enableSpeechToText] as? Bool ?? false
        let enableVoiceProcessing = json[Constants.enableVoiceProcessing] as? Bool ?? false // NEW

        return RecordingSettings(
            path: path,
            encoder: encoder,
            sampleRate: sampleRate,
            bitRate: bitRate,
            fileNameFormat: fileNameFormat,
            useLegacy: useLegacy,
            overrideAudioSession: overrideAudioSession,
            linearPCMBitDepth: linearPCMBitDepth,
            linearPCMIsBigEndian: linearPCMIsBigEndian,
            linearPCMIsFloat: linearPCMIsFloat,
            enableSpeechToText: enableSpeechToText,
            enableVoiceProcessing: enableVoiceProcessing // NEW
        )
    }
}