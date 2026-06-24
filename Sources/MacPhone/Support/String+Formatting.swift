import Foundation

extension String {
    var trimmedOneLine: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }
}
