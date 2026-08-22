import AppKit
import SwiftUI

final class InstalledApplicationIconCache: @unchecked Sendable {
    static let shared = InstalledApplicationIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let fileExists: @Sendable (String) -> Bool
    private let iconProvider: @Sendable (String) -> NSImage

    init(
        countLimit: Int = 128,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        iconProvider: @escaping @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        cache.countLimit = countLimit
        self.fileExists = fileExists
        self.iconProvider = iconProvider
    }

    func image(for applicationURL: URL, version: String) async -> NSImage? {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }

        let path = applicationURL.standardizedFileURL.path
        let key = "\(path)\u{0}\(version)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let fileExists = fileExists
        let iconProvider = iconProvider
        let loadTask = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard fileExists(path) else { return nil }
            return iconProvider(path)
        }
        let image = await loadTask.value
        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct InstalledPackageIcon: View {
    @Environment(BrewService.self)
    private var brewService
    let package: BrewPackage
    var size: CGFloat = 28
    @State private var applicationIcon: NSImage?

    private var applicationURL: URL? {
        brewService.installedApplicationURL(for: package)
    }

    private var request: InstalledApplicationIconRequest? {
        applicationURL.map { InstalledApplicationIconRequest(url: $0, version: package.version) }
    }

    var body: some View {
        ZStack {
            if let applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                PackageSourceIcon(source: package.source, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: request) { @MainActor in
            guard let request else {
                applicationIcon = nil
                return
            }
            applicationIcon = nil
            let image = await InstalledApplicationIconCache.shared.image(
                for: request.url,
                version: request.version
            )
            guard !Task.isCancelled else { return }
            applicationIcon = image
        }
        .accessibilityHidden(true)
    }
}

private struct InstalledApplicationIconRequest: Hashable {
    let url: URL
    let version: String
}
