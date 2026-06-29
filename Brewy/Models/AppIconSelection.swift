import AppKit
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "AppIconSelection")
private let classicAppIconName = "ClassicAppIcon"

enum AppIconSelection: String, CaseIterable, Identifiable {
    case current
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current"
        case .classic: "Classic"
        }
    }

    var previewImage: NSImage {
        switch self {
        case .current:
            NSImage(named: NSImage.applicationIconName) ?? NSImage()
        case .classic:
            NSImage(named: classicAppIconName) ?? NSImage()
        }
    }

    @MainActor
    static func apply(rawValue: String) {
        let selection = Self(rawValue: rawValue) ?? .current

        switch selection {
        case .current:
            NSApplication.shared.applicationIconImage = nil
        case .classic:
            guard let image = NSImage(named: classicAppIconName) else {
                logger.error("Classic app icon asset is missing")
                return
            }
            NSApplication.shared.applicationIconImage = image
        }
    }
}
