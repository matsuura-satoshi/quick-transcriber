import Foundation
@testable import QuickTranscriberLib

/// Orchestrates parameter sweeps driven by a JSON manifest.
/// Stage 1 focuses on transcription-only parameters; Stage 2 adds diarization.
/// Diarization-only keys (similarityThreshold, windowDuration, etc.) that are
/// not part of `TranscriptionParameters` are returned in a residual dict so the
/// caller can apply them to downstream components.
public enum ParameterSweepRunner {
    // MARK: - Manifest model

    public struct Manifest: Codable, Sendable {
        public let stage: Int
        public let outputPath: String
        public let configs: [Config]
    }

    public struct Config: Codable, Sendable {
        public let id: String
        public let dataset: String
        public let subsetSeed: Int
        public let subsetSize: Int
        public let overrides: [String: Value]
    }

    public enum Value: Codable, Sendable, Equatable {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)

        public var doubleValue: Double? {
            switch self {
            case .double(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }

        public var intValue: Int? {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int(v)
            default: return nil
            }
        }

        public var stringValue: String? {
            if case .string(let v) = self { return v }
            return nil
        }

        public var boolValue: Bool? {
            if case .bool(let v) = self { return v }
            return nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let b = try? container.decode(Bool.self) {
                self = .bool(b)
                return
            }
            if let i = try? container.decode(Int.self), !(container.decodeNil() || false) {
                // Prefer Int when value is a whole number with no fractional part.
                // JSON decoder returns Int successfully for both "42" and "42.0"
                // when the target is Int; double-parse first for floats.
                if let d = try? container.decode(Double.self), d != Double(i) {
                    self = .double(d)
                } else {
                    self = .int(i)
                }
                return
            }
            if let d = try? container.decode(Double.self) {
                self = .double(d)
                return
            }
            if let s = try? container.decode(String.self) {
                self = .string(s)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported parameter value type"
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .string(let v): try container.encode(v)
            }
        }
    }

    // MARK: - Errors

    public enum ApplyError: Error, Equatable {
        case unknownKey(String)
        case typeMismatch(key: String, expected: String)
    }

    // MARK: - API

    public static func parseManifest(_ data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Apply `overrides` to `params`. Keys that belong to `TranscriptionParameters`
    /// are consumed; unknown keys that are valid Stage-2 residuals (diarization
    /// component parameters) are returned for downstream wiring. Any key that is
    /// neither recognized as a Stage-1 nor Stage-2 parameter throws.
    @discardableResult
    public static func apply(
        overrides: [String: Value],
        to params: inout TranscriptionParameters
    ) throws -> [String: Value] {
        var residual: [String: Value] = [:]

        for (key, value) in overrides {
            switch key {
            case "temperature":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.temperature = Float(v)
            case "temperatureFallbackCount":
                guard let v = value.intValue else { throw ApplyError.typeMismatch(key: key, expected: "Int") }
                params.temperatureFallbackCount = v
            case "sampleLength":
                guard let v = value.intValue else { throw ApplyError.typeMismatch(key: key, expected: "Int") }
                params.sampleLength = v
            case "concurrentWorkerCount":
                guard let v = value.intValue else { throw ApplyError.typeMismatch(key: key, expected: "Int") }
                params.concurrentWorkerCount = v
            case "chunkDuration":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.chunkDuration = v
            case "silenceCutoffDuration":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.silenceCutoffDuration = v
            case "silenceEnergyThreshold":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.silenceEnergyThreshold = Float(v)
            case "speechOnsetThreshold":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.speechOnsetThreshold = Float(v)
            case "preRollDuration":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.preRollDuration = v
            case "hangoverDuration":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.hangoverDuration = v
            case "silenceLineBreakThreshold":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.silenceLineBreakThreshold = v
            case "enableSpeakerDiarization":
                guard let v = value.boolValue else { throw ApplyError.typeMismatch(key: key, expected: "Bool") }
                params.enableSpeakerDiarization = v
            case "expectedSpeakerCount":
                guard let v = value.intValue else { throw ApplyError.typeMismatch(key: key, expected: "Int") }
                params.expectedSpeakerCount = v
            case "speakerTransitionPenalty":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.speakerTransitionPenalty = v
            case "diarizationMode":
                guard let s = value.stringValue, let mode = DiarizationMode(rawValue: s) else {
                    throw ApplyError.typeMismatch(key: key, expected: "DiarizationMode")
                }
                params.diarizationMode = mode
            case "suppressBlank":
                guard let v = value.boolValue else { throw ApplyError.typeMismatch(key: key, expected: "Bool") }
                params.suppressBlank = v
            case "qualityThresholdMinChunkDuration":
                guard let v = value.doubleValue else { throw ApplyError.typeMismatch(key: key, expected: "Double") }
                params.qualityThresholdMinChunkDuration = v

            // Stage-2 diarization component parameters — pass through to caller.
            case "similarityThreshold",
                 "diarizationChunkDuration",
                 "windowDuration",
                 "profileStrategy":
                residual[key] = value

            default:
                throw ApplyError.unknownKey(key)
            }
        }

        return residual
    }
}
