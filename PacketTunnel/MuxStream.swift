// MuxStream.swift – A single multiplexed stream within a MuxTunnel
// Mirrors Android MuxStream.kt

import Foundation

/// A single bidirectional stream within a @c MuxTunnel.
///
/// Lifecycle: created by MuxTunnel.openStream() → waitForConnect() → read()/write() → close()
final class MuxStream {

    let id: UInt32
    private weak var tunnel: MuxTunnel?

    // Connect latch
    private let connectSemaphore = DispatchSemaphore(value: 0)
    private var connectResult: Result<Void, Error> = .failure(ProxyError.connectionClosed)

    // Incoming data queue
    private var dataQueue: [Data] = []
    private let queueLock = NSLock()
    private let dataSemaphore = DispatchSemaphore(value: 0)

    private var remoteFinished = false
    private var localClosed = false

    init(id: UInt32, tunnel: MuxTunnel) {
        self.id = id
        self.tunnel = tunnel
    }

    // MARK: - Tunnel callbacks

    func onConnectOk() {
        connectResult = .success(())
        connectSemaphore.signal()
    }

    func onConnectFail(_ message: String) {
        connectResult = .failure(ProxyError.connectionFailed(message))
        connectSemaphore.signal()
    }

    func onData(_ data: Data) {
        queueLock.lock()
        guard !remoteFinished else { queueLock.unlock(); return }
        dataQueue.append(data)
        queueLock.unlock()
        dataSemaphore.signal()
    }

    func onFin() {
        queueLock.lock()
        remoteFinished = true
        queueLock.unlock()
        dataSemaphore.signal()
    }

    func onConnectionLost() {
        connectResult = .failure(ProxyError.connectionClosed)
        connectSemaphore.signal()
        queueLock.lock()
        remoteFinished = true
        queueLock.unlock()
        dataSemaphore.signal()
    }

    // MARK: - Public API

    /// Block until the server responds to the CONNECT request.
    func waitForConnect(timeout: TimeInterval = 10) throws {
        let result = connectSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            throw ProxyError.connectionFailed("stream connect timed out")
        }
        try connectResult.get()
    }

    /// Read data from the stream. Blocks until data is available.
    /// Returns nil when the stream is finished (remote FIN or closed).
    func read() -> Data? {
        while true {
            queueLock.lock()
            if !dataQueue.isEmpty {
                let data = dataQueue.removeFirst()
                queueLock.unlock()
                return data
            }
            if remoteFinished || localClosed {
                queueLock.unlock()
                return nil
            }
            queueLock.unlock()

            dataSemaphore.wait()
        }
    }

    /// Write data to the stream via the mux tunnel.
    func write(_ data: Data) {
        guard !localClosed, let tunnel = tunnel else { return }
        tunnel.sendMuxFrame(cmd: MuxTunnel.CMD_DATA, streamId: id, payload: data)
    }

    /// Close the stream. Sends FIN to the remote end.
    func close() {
        guard !localClosed else { return }
        localClosed = true

        tunnel?.sendMuxFrame(cmd: MuxTunnel.CMD_FIN, streamId: id)
        tunnel?.removeStream(id)

        // Unblock any readers
        dataSemaphore.signal()
    }
}
