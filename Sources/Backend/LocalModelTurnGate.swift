import Foundation

/// Lets one conversation at a time generate with the on-device model; the others wait
/// in line, first come first served. The model in memory has a single context, so two
/// turns on it at once would corrupt each other. Cloud providers skip the gate and run
/// in parallel.
public actor LocalModelTurnGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    public init() {}

    public var isBusy: Bool { busy }
    public var waitingCount: Int { waiters.count }

    /// `true` once the caller holds the model; `false` if its task was cancelled while
    /// it waited (it must not call `release()` then).
    public func acquire() async -> Bool {
        if !busy {
            busy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the model to the next conversation in line, or frees it.
    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
