import Foundation

/// Scheduling stays separate from file I/O so cancellation never implies a write was cancelled.
@MainActor
protocol EditorAutosaveScheduling: AnyObject {
    func schedule(_ action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class EditorAutosaveScheduler: EditorAutosaveScheduling {
    private var task: Task<Void, Never>?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
