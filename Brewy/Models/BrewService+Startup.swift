import Foundation

extension BrewService {
    func startPackageUpdates(autoRefreshInterval: Int) {
        scheduleAutoRefresh(interval: autoRefreshInterval)
        guard !packageUpdatesStarted else { return }
        packageUpdatesStarted = true

#if DEBUG
        if BrewyRuntime.isUITesting {
            loadUITestFixtures()
            return
        }
#endif

        loadFromCache()
        guard !BrewyRuntime.isRunningTests else { return }
        initialRefreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
        }
    }

    private func scheduleAutoRefresh(interval: Int) {
        guard scheduledAutoRefreshInterval != interval else { return }
        scheduledAutoRefreshInterval = interval
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard interval > 0, !BrewyRuntime.isRunningTests else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await refresh(isUserInitiated: false)
            }
        }
    }
}
