import SwiftUI

struct AddNodeView: View {
    let viewModel: ProxyViewModel
    var editingNode: ProxyNode? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var uriText = ""
    @State private var parseError = false

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var spKey = ""

    private var isEditing: Bool { editingNode != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isEditing {
                    Picker("Method", selection: $selectedTab) {
                        Text("Scan QR").tag(0)
                        Text("Manual").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                if isEditing || selectedTab == 1 {
                    manualTab
                } else {
                    scanTab
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isEditing ? "Edit Node" : "Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let node = editingNode {
                    name = node.name
                    host = node.host
                    port = String(node.port)
                    spKey = node.spKey ?? ""
                    selectedTab = 1
                }
            }
        }
    }

    private var scanTab: some View {
        VStack(spacing: 20) {
            QRScannerView { code in
                if viewModel.parseAndAddNode(from: code) {
                    dismiss()
                } else {
                    parseError = true
                }
            }
            .frame(height: 280)
            .clipShape(.rect(cornerRadius: 16))
            .padding(.horizontal)

            VStack(spacing: 10) {
                Text("Or paste a connection URI")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("simple://", text: $uriText)
                        .font(.system(.subheadline, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        if viewModel.parseAndAddNode(from: uriText) {
                            dismiss()
                        } else {
                            parseError = true
                        }
                    } label: {
                        Text("Add")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uriText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)

                Button {
                    if let clipboard = UIPasteboard.general.string {
                        uriText = clipboard
                    }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Spacer()
        }
        .alert("Invalid URI", isPresented: $parseError) {
            Button("OK") {}
        } message: {
            Text("Could not parse the URI.\nSupported format: simple://…")
        }
    }

    private var manualTab: some View {
        Form {
            Section("Server") {
                TextField("Name (optional)", text: $name)
                TextField("Host / IP", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }

            Section("SimpleProtocol") {
                TextField("Pre-shared Key (64 hex)", text: $spKey)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                Button(isEditing ? "Save" : "Add Node") {
                    saveNode()
                }
                .frame(maxWidth: .infinity)
                .disabled(!isFormValid)
            }
        }
    }

    private var isFormValid: Bool {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = Int(port), p > 0, p < 65536 else { return false }
        return spKey.count == 64 && CryptoService.hexToData(spKey) != nil
    }

    private func saveNode() {
        guard let portNum = Int(port) else { return }
        let nodeName = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
        let node = ProxyNode(
            id: editingNode?.id ?? UUID(),
            name: nodeName,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNum,
            protocolType: .simpleProtocol,
            spKey: spKey
        )
        if isEditing {
            viewModel.updateNode(node)
        } else {
            viewModel.addNode(node)
        }
        dismiss()
    }
}
