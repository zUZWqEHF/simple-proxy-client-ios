import SwiftUI

struct AddNodeView: View {
    let viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var uriText = ""
    @State private var parseError = false

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var protocolType: ProxyProtocolType = .shadowsocks
    @State private var cipher: ShadowsocksCipher = .aes256Gcm
    @State private var password = ""
    @State private var spKey = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Method", selection: $selectedTab) {
                    Text("Scan QR").tag(0)
                    Text("Manual").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    scanTab
                } else {
                    manualTab
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                    TextField("ss:// or simple://", text: $uriText)
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
            Text("Could not parse the URI. Supported formats:\nss://… or simple://…")
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

            Section("Protocol") {
                Picker("Type", selection: $protocolType) {
                    ForEach(ProxyProtocolType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if protocolType == .shadowsocks {
                    Picker("Cipher", selection: $cipher) {
                        ForEach(ShadowsocksCipher.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    SecureField("Password", text: $password)
                }

                if protocolType == .simpleProtocol {
                    TextField("Pre-shared Key (64 hex)", text: $spKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            Section {
                Button("Add Node") {
                    addManualNode()
                }
                .frame(maxWidth: .infinity)
                .disabled(!isFormValid)
            }
        }
    }

    private var isFormValid: Bool {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = Int(port), p > 0, p < 65536 else { return false }
        switch protocolType {
        case .shadowsocks:
            return !password.isEmpty
        case .simpleProtocol:
            return spKey.count == 64 && CryptoService.hexToData(spKey) != nil
        }
    }

    private func addManualNode() {
        guard let portNum = Int(port) else { return }
        let nodeName = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
        let node = ProxyNode(
            name: nodeName,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNum,
            protocolType: protocolType,
            ssCipher: protocolType == .shadowsocks ? cipher : nil,
            ssPassword: protocolType == .shadowsocks ? password : nil,
            spKey: protocolType == .simpleProtocol ? spKey : nil
        )
        viewModel.addNode(node)
        dismiss()
    }
}
