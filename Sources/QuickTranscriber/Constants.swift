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
}
