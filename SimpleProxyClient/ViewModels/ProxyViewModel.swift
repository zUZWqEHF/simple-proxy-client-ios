import SwiftUI

@Observable
final class ProxyViewModel {
    var nodes: [ProxyNode] = []
    var selectedNodeId: UUID?
    var routingMode: RoutingMode = .global
    var showAddNode = false
    var showError = false
    var errorMessage = ""

    let tunnelManager = TunnelManager()
    private let store = NodeStore()

    var connectionStatus: ConnectionStatus {
        tunnelManager.status
    }

    var selectedNode: ProxyNode? {
        nodes.first { $0.id == selectedNodeId }
    }

    init() {
        nodes = store.loadNodes()
        selectedNodeId = store.loadSelectedNodeId() ?? nodes.first?.id
        routingMode = store.loadRoutingMode()
    }

    func addNode(_ node: ProxyNode) {
        nodes.append(node)
        if selectedNodeId == nil { selectedNodeId = node.id }
        save()
    }

    func deleteNode(_ node: ProxyNode) {
        nodes.removeAll { $0.id == node.id }
        if selectedNodeId == node.id { selectedNodeId = nodes.first?.id }
        save()
    }

    func deleteNodes(at offsets: IndexSet) {
        let removing = offsets.map { nodes[$0] }
        nodes.remove(atOffsets: offsets)
        if removing.contains(where: { $0.id == selectedNodeId }) {
            selectedNodeId = nodes.first?.id
        }
        save()
    }

    func selectNode(_ node: ProxyNode) {
        selectedNodeId = node.id
        store.saveSelectedNodeId(selectedNodeId)
    }

    func setRoutingMode(_ mode: RoutingMode) {
        routingMode = mode
        store.saveRoutingMode(mode)
        // Reconnect with new routing mode if currently connected
        if connectionStatus == .connected {
            disconnect()
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms for clean disconnect
                connect()
            }
        }
    }

    func toggleConnection() {
        switch connectionStatus {
        case .disconnected:
            connect()
        case .connected:
            disconnect()
        default:
            break
        }
    }

    func parseAndAddNode(from uri: String) -> Bool {
        guard let node = NodeParser.parse(uri) else { return false }
        addNode(node)
        return true
    }

    private func connect() {
        guard let node = selectedNode else {
            showErrorWith("Please add and select a node first")
            return
        }
        Task {
            do {
                try await tunnelManager.startTunnel(node: node, routingMode: routingMode)
            } catch {
                showErrorWith(error.localizedDescription)
            }
        }
    }

    private func disconnect() {
        tunnelManager.stopTunnel()
    }

    private func save() {
        store.saveNodes(nodes)
        store.saveSelectedNodeId(selectedNodeId)
    }

    private func showErrorWith(_ message: String) {
        errorMessage = message
        showError = true
    }
}
