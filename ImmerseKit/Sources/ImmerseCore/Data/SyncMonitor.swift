import CoreData
import Foundation

/// Reacts to changes that arrive from CloudKit: merges duplicates, then tells the stores to re-read.
/// Remote changes come in bursts, so handling is debounced.
@MainActor
public final class SyncMonitor {
    private let repository: SwiftDataTaskRepository
    private let onChange: () -> Void
    private let debounce: Duration
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    public init(repository: SwiftDataTaskRepository, debounce: Duration = .seconds(1), onChange: @escaping () -> Void) {
        self.repository = repository
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Runs one dedupe pass right away (catches duplicates from a previous run) and starts listening
    public func start() {
        _ = try? DedupeService.run(in: repository.context)
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    public func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        pending?.cancel()
    }

    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            _ = try? DedupeService.run(in: repository.context)
            onChange()
        }
    }
}
