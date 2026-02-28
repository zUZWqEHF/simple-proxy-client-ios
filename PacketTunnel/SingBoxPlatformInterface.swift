// SingBoxPlatformInterface.swift – Implements LibboxPlatformInterfaceProtocol
// Simplified from sing-box-for-apple's ExtensionPlatformInterface.swift
// Only implements what's needed for Global proxy mode.

import Foundation
import NetworkExtension
import Libbox
import Network

public class SingBoxPlatformInterface: NSObject,
    LibboxPlatformInterfaceProtocol,
    LibboxCommandServerHandlerProtocol {

    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private let serverAddress: String  // proxy server host, excluded from TUN routes

    init(tunnel: PacketTunnelProvider, serverAddress: String) {
        self.tunnel = tunnel
        self.serverAddress = serverAddress
    }

    // MARK: - TUN

    public func openTun(_ options: LibboxTunOptionsProtocol?,
                         ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTunAsync(options, ret0_)
        }
    }

    private func openTunAsync(_ options: LibboxTunOptionsProtocol?,
                               _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options else { throw makeError("nil TUN options") }
        guard let ret0_ else { throw makeError("nil return pointer") }
        guard let tunnel else { throw makeError("tunnel deallocated") }

        // Resolve the proxy server address to an IP for tunnelRemoteAddress.
        // tunnelRemoteAddress tells iOS which address is the "VPN server" so it
        // gets excluded from TUN routing — this prevents the routing loop.
        let resolvedIPs = SingBoxPlatformInterface.resolveHost(serverAddress)
        let tunnelRemote = resolvedIPs.first(where: { !$0.contains(":") }) ?? resolvedIPs.first ?? serverAddress

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemote)
        settings.mtu = NSNumber(value: options.getMTU())

        // DNS
        if let dnsServer = try? options.getDNSServerAddress() {
            let dns = NEDNSSettings(servers: [dnsServer.value])
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }

        // IPv4
        var ipv4Addr: [String] = []
        var ipv4Mask: [String] = []
        if let iter = options.getInet4Address() {
            while iter.hasNext() {
                if let prefix = iter.next() {
                    ipv4Addr.append(prefix.address())
                    ipv4Mask.append(prefix.mask())
                }
            }
        }

        let ipv4 = NEIPv4Settings(addresses: ipv4Addr, subnetMasks: ipv4Mask)
        ipv4.includedRoutes = [NEIPv4Route.default()]

        // Exclude routes from sing-box
        var excludedRoutes: [NEIPv4Route] = []
        if let iter = options.getInet4RouteExcludeAddress() {
            while iter.hasNext() {
                if let prefix = iter.next() {
                    excludedRoutes.append(
                        NEIPv4Route(destinationAddress: prefix.address(),
                                    subnetMask: prefix.mask())
                    )
                }
            }
        }

        // Exclude proxy server IP from TUN routes to prevent routing loop.
        // Without this, the MuxTunnel socket's traffic loops back through TUN
        // and never reaches the real server.
        var excludedIPv6Routes: [NEIPv6Route] = []
        for ip in resolvedIPs {
            if ip.contains(":") {
                excludedIPv6Routes.append(
                    NEIPv6Route(destinationAddress: ip, networkPrefixLength: 128)
                )
            } else {
                excludedRoutes.append(
                    NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255")
                )
            }
        }
        if resolvedIPs.isEmpty {
            NSLog("[Platform] WARNING: could not resolve server address '%@', route exclusion skipped", serverAddress)
        }

        ipv4.excludedRoutes = excludedRoutes
        settings.ipv4Settings = ipv4

        // IPv6
        var ipv6Addr: [String] = []
        var ipv6Prefix: [NSNumber] = []
        if let iter = options.getInet6Address() {
            while iter.hasNext() {
                if let prefix = iter.next() {
                    ipv6Addr.append(prefix.address())
                    ipv6Prefix.append(NSNumber(value: prefix.prefix()))
                }
            }
        }
        if !ipv6Addr.isEmpty || !excludedIPv6Routes.isEmpty {
            let finalAddrs = ipv6Addr.isEmpty ? ["fd00::1"] : ipv6Addr
            let finalPrefixes = ipv6Prefix.isEmpty ? [NSNumber(value: 128)] : ipv6Prefix
            let ipv6 = NEIPv6Settings(addresses: finalAddrs,
                                       networkPrefixLengths: finalPrefixes)
            ipv6.includedRoutes = [NEIPv6Route.default()]
            if !excludedIPv6Routes.isEmpty {
                ipv6.excludedRoutes = excludedIPv6Routes
            }
            settings.ipv6Settings = ipv6
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        // Get TUN file descriptor
        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw makeError("missing TUN file descriptor")
        }
    }

    // MARK: - Interface monitoring

    public func usePlatformAutoDetectControl() -> Bool { false }
    public func autoDetectControl(_ fd: Int32) throws {}

    public func findConnectionOwner(_ fd: Int32, sourceAddress _: String?,
                                     sourcePort _: Int32, destinationAddress _: String?,
                                     destinationPort _: Int32,
                                     ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw makeError("not implemented")
    }

    public func packageName(byUid _: Int32, error _: NSErrorPointer) -> String { "" }
    public func uid(byPackageName _: String?, ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw makeError("not implemented")
    }
    public func useProcFS() -> Bool { false }

    // MARK: - Logging

    public func writeLog(_ message: String?) {
        guard let message else { return }
        NSLog("[sing-box] %@", message)
    }

    // MARK: - Network monitor

    public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onPathUpdate(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                self.onPathUpdate(listener, path)
            }
        }
        monitor.start(queue: .global())
        semaphore.wait()
    }

    private func onPathUpdate(_ listener: LibboxInterfaceUpdateListenerProtocol,
                               _ path: Network.NWPath) {
        if path.status == .unsatisfied {
            listener.updateDefaultInterface("", interfaceIndex: -1,
                                             isExpensive: false, isConstrained: false)
        } else if let iface = path.availableInterfaces.first {
            listener.updateDefaultInterface(iface.name,
                                             interfaceIndex: Int32(iface.index),
                                             isExpensive: path.isExpensive,
                                             isConstrained: path.isConstrained)
        }
    }

    public func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor = nwMonitor else { throw makeError("monitor not started") }
        let path = monitor.currentPath
        if path.status == .unsatisfied {
            return InterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let iface = LibboxNetworkInterface()
            iface.name = it.name
            iface.index = Int32(it.index)
            switch it.type {
            case .wifi: iface.type = LibboxInterfaceTypeWIFI
            case .cellular: iface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: iface.type = LibboxInterfaceTypeEthernet
            default: iface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(iface)
        }
        return InterfaceArray(interfaces)
    }

    // MARK: - Misc

    public func underNetworkExtension() -> Bool { true }
    public func includeAllNetworks() -> Bool { false }

    public func clearDNSCache() {
        guard let settings = networkSettings, let tunnel else { return }
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(nil) { _ in }
        tunnel.setTunnelNetworkSettings(settings) { _ in }
        tunnel.reasserting = false
    }

    public func readWIFIState() -> LibboxWIFIState? { nil }

    public func serviceReload() throws {
        // Not needed for simple proxy
    }

    public func postServiceClose() {
        reset()
    }

    public func getSystemProxyStatus() -> LibboxSystemProxyStatus? {
        LibboxSystemProxyStatus()
    }

    public func setSystemProxyEnabled(_ isEnabled: Bool) throws {}

    public func send(_ notification: LibboxNotification?) throws {}

    public func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    public func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func reset() {
        networkSettings = nil
    }

    // MARK: - Helpers

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "SimpleProxyPlatform", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Resolve a hostname to all its IP addresses (IPv4 and IPv6).
    private static func resolveHost(_ host: String) -> [String] {
        var results: [String] = []

        // Check if it's already an IP address
        var addr4 = in_addr()
        var addr6 = in6_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            return [host]
        }
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            return [host]
        }

        // DNS resolution
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let addrInfo = result else {
            NSLog("[Platform] resolveHost failed for '%@': %d", host, rc)
            return []
        }
        defer { freeaddrinfo(result) }

        var ptr: UnsafeMutablePointer<addrinfo>? = addrInfo
        while let ai = ptr {
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen,
                           &hostBuf, socklen_t(hostBuf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ipStr = String(cString: hostBuf)
                if !results.contains(ipStr) {
                    results.append(ipStr)
                }
            }
            ptr = ai.pointee.ai_next
        }
        return results
    }

    // MARK: - Interface iterator

    private class InterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?
        init(_ array: [LibboxNetworkInterface]) { iterator = array.makeIterator() }
        func hasNext() -> Bool { nextValue = iterator.next(); return nextValue != nil }
        func next() -> LibboxNetworkInterface? { nextValue }
    }
}
