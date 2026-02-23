# Simple Proxy Client iOS - Setup Guide

## Architecture

```
Main App (SimpleProxyClient)
├── UI (SwiftUI views)
├── TunnelManager → NETunnelProviderManager
└── Node management (add/delete/select)

PacketTunnel Extension (new target)
├── PacketTunnelProvider (NEPacketTunnelProvider)
├── SingBoxPlatformInterface (LibboxPlatformInterfaceProtocol)
├── SingBoxConfigBuilder (generates sing-box JSON)
├── SimpleProtocolBridge (SOCKS5 → SimpleProtocol)
└── ProxyTunnel (AES-GCM encrypted tunnel)

Data Flow:
  App traffic → TUN → sing-box (Libbox)
    → socks outbound → 127.0.0.1:16080 (bridge)
    → SimpleProtocol encrypted tunnel → remote server
```

## Prerequisites

- Xcode 15+ with iOS 17+ SDK
- Go 1.22+ (for building Libbox): `brew install go`
- Apple Developer account with Network Extension entitlement

## Step 1: Build Libbox.xcframework

```bash
cd simple-proxy-client-ios
./build_libbox.sh 1.12.22
```

This clones sing-box, builds the Go library for iOS via gomobile, and outputs
`Libbox.xcframework` in the project directory.

If the script fails, you can build manually:
```bash
# Install gomobile
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.8
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.8

# Clone and build
git clone --depth 1 --branch v1.12.22 https://github.com/SagerNet/sing-box.git
cd sing-box
go run ./cmd/internal/build_libbox -target apple -platform ios
# Copy the resulting Libbox.xcframework to the project
```

## Step 2: Create PacketTunnel Extension Target in Xcode

1. Open `SimpleProxyClient.xcodeproj` in Xcode
2. **File → New → Target...**
3. Select **Network Extension**
4. Configure:
   - Product Name: `PacketTunnel`
   - Bundle Identifier: `app.rork.simple-proxy-client.PacketTunnel`
   - Language: Swift
   - Provider Type: Packet Tunnel Provider
5. When asked to activate the scheme, click **Activate**
6. **Delete** the auto-generated `PacketTunnelProvider.swift` in the new target
   (we have our own implementation)

## Step 3: Add Source Files to Extension Target

1. In Xcode, right-click the **PacketTunnel** group
2. **Add Files to "SimpleProxyClient"...**
3. Select all files in `PacketTunnel/`:
   - `PacketTunnelProvider.swift`
   - `SingBoxPlatformInterface.swift`
   - `SingBoxConfigBuilder.swift`
   - `SimpleProtocolBridge.swift`
   - `ProxyTunnel.swift`
   - `RunBlocking.swift`
4. Make sure **Target Membership** is set to `PacketTunnel` only

5. Also add `SimpleProxyClient/Services/CryptoService.swift` to the
   **PacketTunnel** target (select the file, check PacketTunnel in Target Membership)

## Step 4: Add Libbox.xcframework

1. Drag `Libbox.xcframework` into the Xcode project navigator
2. In the dialog:
   - Check **Copy items if needed**
   - Add to target: **PacketTunnel** (the extension, not the main app)
3. Select the **PacketTunnel** target → **General** → **Frameworks and Libraries**
4. Verify `Libbox.xcframework` is listed and set to **Embed & Sign**

## Step 5: Configure Entitlements

### Main App (`SimpleProxyClient.entitlements`):
Already configured with:
- `com.apple.developer.networking.networkextension` → `packet-tunnel-provider`
- `com.apple.developer.networking.vpn.api` → `allow-vpn`
- `com.apple.security.application-groups` → `group.app.rork.simple-proxy-client`

### Extension (`PacketTunnel/PacketTunnel.entitlements`):
1. Select the **PacketTunnel** target
2. **Build Settings** → search "Code Signing Entitlements"
3. Set to `PacketTunnel/PacketTunnel.entitlements`
4. Verify it matches the provided file

### Apple Developer Portal:
1. Create an App ID for the extension: `app.rork.simple-proxy-client.PacketTunnel`
2. Enable capabilities:
   - Network Extensions (Packet Tunnel)
   - App Groups (`group.app.rork.simple-proxy-client`)
3. Create a provisioning profile for the extension

## Step 6: Configure Build Settings

### PacketTunnel target:
- **Deployment Target**: iOS 17.0 (match main app)
- **Info.plist**: `PacketTunnel/Info.plist`
- **Code Signing Entitlements**: `PacketTunnel/PacketTunnel.entitlements`

### Main App target:
- **Embed App Extensions**: Verify PacketTunnel is listed in Embed Extensions

## Step 7: Build & Run

1. Select the main app target (SimpleProxyClient)
2. Build for a real device (extensions don't work in Simulator)
3. Test:
   - Add a SimpleProtocol node (scan QR or paste `simple://` URI)
   - Tap the connect button
   - iOS will ask for VPN permission on first use
   - Traffic should route through the proxy

## Troubleshooting

### "Missing configuration" error
The PacketTunnel extension couldn't read the node config. Check that
TunnelManager is passing `host`, `port`, and `key` in `providerConfiguration`.

### VPN permission not granted
Go to Settings → General → VPN & Device Management and verify the VPN profile.

### "missing TUN file descriptor"
This usually means the network settings weren't applied. Check that the
app group identifier matches between main app and extension.

### Build error: "No such module 'Libbox'"
Make sure `Libbox.xcframework` is added to the PacketTunnel target's
Frameworks and Libraries with "Embed & Sign".

### Bridge connection fails
Check that:
1. The node host/port are correct
2. The pre-shared key (64 hex chars) matches the server
3. The server is reachable from the device's network
