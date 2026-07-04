import AppKit

enum BrewfilePicker {

    @MainActor
    static func choosePath() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Brewfile"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
