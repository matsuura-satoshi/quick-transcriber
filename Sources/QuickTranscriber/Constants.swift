import Foundation

public enum Constants {
    public enum Audio {
        public static let sampleRate: Double = 16000.0
        public static let sampleRateInt: Int = 16000
    }

    public enum VAD {
        public static let defaultMaxChunkDuration: TimeInterval = 8.0
        public static let defaultEndOfUtteranceSilence: TimeInterval = 0.6
        public static let defaultSilenceEnergyThreshold: Float = 0.01
        public static let defaultSpeechOnsetThreshold: Float = 0.02
        public static let defaultPreRollDuration: TimeInterval = 0.3
        public static let defaultHangoverDuration: TimeInterval = 0.15
        public static let defaultMinimumUtteranceDuration: TimeInterval = 0.3
    }

    public enum AudioNormalization {
        public static let targetPeak: Float = 0.5
        public static let minGain: Float = 1.0
        public static let maxGain: Float = 10.0
        public static let windowDuration: TimeInterval = 1.0
        public static let attackCoefficient: Float = 0.1
        public static let releaseCoefficient: Float = 0.01
    }

    public enum Embedding {
        public static let similarityThreshold: Float = 0.5
        /// Auto mode で correctAssignment が新 embedding を profile に追加するときの confidence。
        /// 1.0 だと 1 回の修正で centroid が大きくシフトし、汚染フィードバックループを起こす。
        public static let userCorrectionConfidence: Float = 0.3
        /// Manual mode の post-hoc 学習で適用する weighted merge の α 上限。
        public static let sessionLearningAlphaMax: Float = 0.2
        /// α が上限に達するために必要なサンプル数。
        public static let sessionLearningSamplesForMaxAlpha: Int = 50
        /// post-hoc 学習を行う最小サンプル数。これ未満の場合はノイズ過大とみなしスキップ。
        public static let sessionLearningMinSamples: Int = 3
        /// identify() の tie-breaker で「ほぼ同値」とみなす similarity 差の閾値。
        public static let tieBreakerEpsilon: Float = 0.005
    }

    public enum QualityFilter {
        public static let noSpeechProbThreshold: Float = 0.7
        public static let avgLogprobThreshold: Float = -1.5
    }

    public enum Diarization {
        /// Maximum time to wait for a single diarization process() call.
        public static let processTimeout: TimeInterval = 10.0
    }

    public enum Version {
        public static let major = 2
        public static let minor = 3
        public static let patch = 76
        public static let string = "\(major).\(minor).\(patch)"
        public static let versionString = "v\(string)"
    }

    public enum GitHub {
        public static let owner = "matsuura-satoshi"
        public static let repo = "quick-transcriber"
    }

    public enum AudioRecording {
        public static let fileSuffix = "_qt_recording"
        public static let sampleRate: UInt32 = 16000
        public static let channels: UInt16 = 1
        public static let bitsPerSample: UInt16 = 16
    }

    public enum FileTranscription {
        public static let chunkDuration: TimeInterval = 25.0
        public static let endOfUtteranceSilence: TimeInterval = 1.0
        public static let temperatureFallbackCount: Int = 2
        public static let qualityThresholdMinChunkDuration: TimeInterval = 15.0
    }

    public enum Translation {
        public static let groupBoundarySilence: TimeInterval = 2.0
        public static let sentenceEndersEN: Set<Character> = [".", "!", "?"]
        public static let sentenceEndersJA: Set<Character> = ["。", "！", "？"]
    }
}
