import Foundation

/// File access and JSON coding are serialized off the UI actor.
actor ArchiveFileIO {
    func read<Value: Decodable>(_ type: Value.Type, from file: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    func write<Value: Encodable>(_ value: Value, to file: URL) throws {
        let bytes = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }

    func backup(_ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: file.deletingPathExtension().appendingPathExtension("backup-\(UUID().uuidString).json"))
        }
    }
}

struct ArchiveRefreshRequest {
    var authorize: Bool
    var scanRoutes: Bool
    var force = false
    var changed = false
}

/// All callers await the same drain. Only new data or stronger capabilities need another pass.
@MainActor
final class ArchiveRefreshGate {
    private var task: Task<Void, Never>?
    private var active: ArchiveRefreshRequest?
    private var pending: ArchiveRefreshRequest?
    private var lastSuccess: Date?
    private var lastCapabilities: ArchiveRefreshRequest?
    private let interval: TimeInterval
    private let now: () -> Date

    init(interval: TimeInterval = 60, now: @escaping () -> Date = { .now }) {
        self.interval = interval; self.now = now
    }

    func refresh(_ request: ArchiveRefreshRequest, operation: @escaping @MainActor (ArchiveRefreshRequest) async -> Bool) async {
        if let task {
            if let active, request.changed || (request.authorize && !active.authorize) || (request.scanRoutes && !active.scanRoutes) {
                let previous = pending ?? active
                pending = ArchiveRefreshRequest(authorize: previous.authorize || request.authorize,
                    scanRoutes: previous.scanRoutes || request.scanRoutes, force: true, changed: true)
            }
            await task.value
            return
        }
        if !request.force && !request.changed, let lastSuccess, let lastCapabilities,
           (!request.authorize || lastCapabilities.authorize), (!request.scanRoutes || lastCapabilities.scanRoutes),
           now().timeIntervalSince(lastSuccess) >= 0, now().timeIntervalSince(lastSuccess) < interval { return }
        active = request
        let work = Task { @MainActor in
            var next: ArchiveRefreshRequest? = request
            while let current = next {
                self.active = current
                self.pending = nil
                if await operation(current) { self.lastSuccess = self.now(); self.lastCapabilities = current }
                next = self.pending
            }
            self.active = nil
            self.task = nil
        }
        task = work
        await work.value
    }
}

/// Bridges callback queries to task cancellation. Completion and cancellation race under one lock.
final class ArchiveQueryContinuation<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var stop: (() -> Void)?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Value, Error>, execute: () -> Void, stop: @escaping () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.stop = stop
        // Register and execute atomically with respect to cancellation, so a cancelled query
        // cannot start after stop() has already run. Recursive locking permits inline completion.
        execute()
        lock.unlock()
    }
    func resume(returning value: Value) { finish(.success(value)) }
    func resume(throwing error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil; stop = nil
        lock.unlock()
        pending?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation, cancelQuery = stop
        continuation = nil; stop = nil
        lock.unlock()
        cancelQuery?()
        pending?.resume(throwing: CancellationError())
    }
}
