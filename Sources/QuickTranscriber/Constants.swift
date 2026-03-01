import Foundation

public enum Constants {
    public enum Audio {
        public static let sampleRate: Double = 16000.0
        public static let sampleRateInt: Int = 16000
        public static let silenceSkipThreshold: Float = 0.005
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
        public static let major = 1
        public static let minor = 0
        public static let patch = 58
        public static let string = "\(major).\(minor).\(patch)"
    }

    public enum Translation {
        public static let groupBoundarySilence: TimeInterval = 2.0
        public static let sentenceEndersEN: Set<Character> = [".", "!", "?"]
        public static let sentenceEndersJA: Set<Character> = ["。", "！", "？"]
    }
}
