import Foundation

public enum LabelUtils {
    /// Generate the next available speaker label not in `usedLabels`.
    /// Sequence: A-Z → AA-AZ → BA-BZ → ... → ZA-ZZ → Z{count}
    public static func nextAvailableLabel(usedLabels: Set<String>) -> String {
        // Single letters A-Z
        for i in 0..<26 {
            let label = String(UnicodeScalar(UInt8(65 + i)))
            if !usedLabels.contains(label) { return label }
        }
        // Double letters AA-ZZ
        for i in 0..<26 {
            for j in 0..<26 {
                let label = String(UnicodeScalar(UInt8(65 + i))) + String(UnicodeScalar(UInt8(65 + j)))
                if !usedLabels.contains(label) { return label }
            }
        }
        return "Z\(usedLabels.count)"
    }
}
