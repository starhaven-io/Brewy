import Foundation

enum BrewError: LocalizedError {
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output):
            return Self.summarize(command: command, output: output)
        }
    }

    private static let maxOutputChars = 800

    private static func summarize(command: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "brew \(command) failed." }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if let errorLine = lines.first(where: { $0.lowercased().hasPrefix("error:") }) {
            return String(errorLine)
        }
        let tail = lines.suffix(6).joined(separator: "\n")
        if tail.count <= maxOutputChars { return tail }
        return "…" + String(tail.suffix(maxOutputChars))
    }
}
