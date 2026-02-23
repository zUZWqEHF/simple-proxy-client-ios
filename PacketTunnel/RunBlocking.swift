// RunBlocking.swift – Bridges async/await to synchronous context
// Required by LibboxPlatformInterfaceProtocol callbacks that are synchronous.

import Foundation

/// Execute an async closure synchronously.  Used by the Libbox platform
/// interface which calls back on a non-async thread.
func runBlocking<T>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do {
            let value = try await body()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
