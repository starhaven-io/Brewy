extension ActionHistoryEntry {
    var isMutatingCommand: Bool {
        guard let command = arguments.first else { return false }
        return Self.mutatingCommands.contains(command)
    }

    private static let mutatingCommands: Set<String> = [
        "install", "uninstall", "upgrade", "reinstall",
        "pin", "unpin", "link", "unlink", "autoremove", "cleanup", "update",
        "tap", "untap"
    ]

    static let recordedOutputByteLimit = 65_536

    static func truncatedOutput(_ output: String) -> String {
        let totalBytes = output.utf8.count
        guard totalBytes > recordedOutputByteLimit else { return output }

        var omittedBytes = totalBytes - recordedOutputByteLimit
        var result = ""
        for _ in 0..<3 {
            let marker = "\n… [\(omittedBytes) bytes omitted] …\n"
            let contentBudget = max(0, recordedOutputByteLimit - marker.utf8.count)
            let head = UTF8ByteTruncation.prefix(output, maxBytes: contentBudget / 2)
            let tail = UTF8ByteTruncation.suffix(output, maxBytes: contentBudget - head.utf8.count)
            result = head + marker + tail
            omittedBytes = totalBytes - head.utf8.count - tail.utf8.count
        }
        return result
    }
}
