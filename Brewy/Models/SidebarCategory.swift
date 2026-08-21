enum SidebarCategory: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case formulae = "Formulae"
    case casks = "Casks"
    case masApps = "Mac App Store"
    case outdated = "Outdated"
    case pinned = "Pinned"
    case leaves = "Leaves"
    case taps = "Taps"
    case services = "Services"
    case groups = "Groups"
    case bundle = "Bundle"
    case history = "History"
    case discover = "Discover"
    case security = "Security"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .installed: "shippingbox.fill"
        case .formulae: "terminal.fill"
        case .casks: "macwindow"
        case .masApps: "app.badge.fill"
        case .outdated: "arrow.triangle.2.circlepath"
        case .pinned: "pin.fill"
        case .leaves: "leaf.fill"
        case .taps: "spigot.fill"
        case .services: "gearshape.2"
        case .groups: "folder.fill"
        case .bundle: "doc.text.fill"
        case .history: "clock.arrow.circlepath"
        case .discover: "magnifyingglass"
        case .security: "shield.checkered"
        case .maintenance: "wrench.and.screwdriver.fill"
        }
    }

    static let packageCategories: [Self] = [
        .installed, .formulae, .casks, .masApps, .outdated, .pinned, .leaves
    ]
    static let managementCategories: [Self] = [.taps, .services, .groups, .bundle]
    static let toolCategories: [Self] = [.history, .discover, .security, .maintenance]
}
