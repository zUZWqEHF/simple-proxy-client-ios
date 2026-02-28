import SwiftUI

struct MainView: View {
    @State private var viewModel = ProxyViewModel()

    private var statusColor: Color {
        switch viewModel.connectionStatus {
        case .disconnected: .secondary
        case .connecting, .disconnecting: .orange
        case .connected: .green
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    nodesSection
                        .padding(.top, 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("simple proxy")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.showAddNode = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showAddNode) {
                AddNodeView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showEditNode) {
                if let node = viewModel.editingNode {
                    AddNodeView(viewModel: viewModel, editingNode: node)
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text(viewModel.connectionStatus.displayText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.connectionStatus)

                if let node = viewModel.selectedNode {
                    Text(node.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No node selected")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            ConnectionButton(
                status: viewModel.connectionStatus,
                action: { viewModel.toggleConnection() }
            )

            // Routing mode picker
            Picker("Routing", selection: Binding(
                get: { viewModel.routingMode },
                set: { viewModel.setRoutingMode($0) }
            )) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [statusColor.opacity(0.05), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NODES")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.nodes.isEmpty {
                    Text("\(viewModel.nodes.count)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)

            if viewModel.nodes.isEmpty {
                emptyState
                    .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.nodes) { node in
                        NodeRowView(
                            node: node,
                            isSelected: node.id == viewModel.selectedNodeId,
                            onSelect: { viewModel.selectNode(node) },
                            onEdit: { viewModel.editNode(node) },
                            onDelete: { viewModel.deleteNode(node) }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No nodes configured")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Node") { viewModel.showAddNode = true }
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 16))
    }
}
