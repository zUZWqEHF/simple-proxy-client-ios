import Foundation

final class NodeStore {
    private let defaults: UserDefaults
    private let nodesKey = "saved_nodes"
    private let selectedKey = "selected_node_id"
    private let routingKey = "routing_mode"

    init() {
        defaults = UserDefaults(suiteName: "group.app.rork.simple-proxy-client") ?? .standard
    }

    func loadNodes() -> [ProxyNode] {
        guard let data = defaults.data(forKey: nodesKey) else { return [] }
        return (try? JSONDecoder().decode([ProxyNode].self, from: data)) ?? []
    }

    func saveNodes(_ nodes: [ProxyNode]) {
        defaults.set(try? JSONEncoder().encode(nodes), forKey: nodesKey)
    }

    func loadSelectedNodeId() -> UUID? {
        guard let string = defaults.string(forKey: selectedKey) else { return nil }
        return UUID(uuidString: string)
    }

    func saveSelectedNodeId(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedKey)
    }

    func loadRoutingMode() -> RoutingMode {
        guard let raw = defaults.string(forKey: routingKey) else { return .global }
        return RoutingMode(rawValue: raw) ?? .global
    }

    func saveRoutingMode(_ mode: RoutingMode) {
        defaults.set(mode.rawValue, forKey: routingKey)
    }
}
