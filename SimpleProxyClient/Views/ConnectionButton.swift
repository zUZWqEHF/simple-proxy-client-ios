import SwiftUI

struct ConnectionButton: View {
    let status: ConnectionStatus
    let action: () -> Void

    @State private var phase: CGFloat = 0

    private let size: CGFloat = 150

    private var color: Color {
        switch status {
        case .disconnected: .gray
        case .connecting, .disconnecting: .orange
        case .connected: .green
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + phase * 0.4)
                    .opacity((1 - phase) * 0.7)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.12), color.opacity(0.03)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(color.opacity(0.35), lineWidth: 2)
                    )

                Image(systemName: "power")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size + 80, height: size + 80)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: status)
        .onAppear(perform: updateAnimation)
        .onChange(of: status) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if status.isActive {
            phase = 0
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
        } else {
            withAnimation(.easeOut(duration: 0.4)) {
                phase = 0
            }
        }
    }
}
