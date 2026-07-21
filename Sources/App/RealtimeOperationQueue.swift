import Foundation

actor RealtimeOperationQueue {
    private var tailTask: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previousTask = tailTask
        let nextTask = Task {
            _ = await previousTask?.value
            await operation()
        }
        tailTask = nextTask
    }

    func reset() {
        tailTask = nil
    }
}
