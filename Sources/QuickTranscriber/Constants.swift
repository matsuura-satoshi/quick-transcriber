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

    public enum Embedding {
        public static let similarityThreshold: Float = 0.5
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
        public static let minor = 1
        public static let patch = 66
        public static let string = "\(major).\(minor).\(patch)"
        public static let versionString = "v\(string)"
    }

    public enum GitHub {
        public static let owner = "matsuura-satoshi"
        public static let repo = "quick-transcriber"
    }

    public enum Translation {
        public static let groupBoundarySilence: TimeInterval = 2.0
        public static let sentenceEndersEN: Set<Character> = [".", "!", "?"]
        public static let sentenceEndersJA: Set<Character> = ["。", "！", "？"]
    }
}
