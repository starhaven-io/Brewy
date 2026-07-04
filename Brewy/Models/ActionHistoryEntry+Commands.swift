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
}
