import Foundation

@MainActor
final class HealthChecker {
    private var pollingTask: Task<Void, Never>?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: config)
    }

    /// Poll until the backend answers, reporting progress along the way.
    ///
    /// - Parameter onWaiting: called each second once startup passes
    ///   `healthSlowAfter`, with the elapsed time, so the UI can show that
    ///   something is still happening rather than appearing to hang.
    ///
    /// Polling continues until the backend is healthy, the ceiling passes, or
    /// the task is cancelled. It previously returned at the timeout, so a
    /// backend that became healthy a few seconds later was never noticed and a
    /// transient slowness turned into permanent failure. (#101)
    func startPollingBackend(
        port: Int,
        onWaiting: @escaping @MainActor (TimeInterval) -> Void = { _ in },
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        stopPolling()

        pollingTask = Task { @MainActor in
            let startTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.healthPollInterval))
                if Task.isCancelled { return }

                let healthy = await checkHealth(urlString: Constants.backendHealthURL(port: port))
                if healthy {
                    completion(true)
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > Constants.healthTimeout {
                    completion(false)
                    return
                }
                if elapsed > Constants.healthSlowAfter {
                    onWaiting(elapsed)
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    nonisolated private func checkHealth(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}
