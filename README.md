# Simple Proxy Client (iOS)

An iOS client for [SimpleProtocol](https://github.com/zUZWqEHF/simple-proxy-server) — a lightweight, encrypted proxy protocol with multiplexing and smart routing.

## Architecture

```
┌──────────────────────────── iOS Device ────────────────────────────┐
│                                                                    │
│  Apps (browser, etc.)                                              │
│       │  TCP / UDP                                                 │
│       ▼                                                            │
│  ┌─────────┐     IP packets      ┌──────────────────────────┐     │
│  │ TUN fd  │ ──────────────────→ │ Packet Reader (userspace│     │
│  │ 10.0.0.2│ ←──────────────── │  TCP stack + DNS proxy)  │     │
│  └─────────┘    crafted packets  └──────────┬──────────────┘     │
│                                              │ TCP connect       │
│                                              ▼                   │
│                                   ┌──────────────────────┐      │
│                                   │ sing-box (mixed-in)  │      │
│                                   │ 127.0.0.1:2080       │      │
│                                   │                      │      │
│                                   │ ┌──────────────────┐ │      │
│                                   │ │  Route decision  │ │      │
│                                   │ │  • intl → proxy  │ │      │
│                                   │ │  • domestic→direct│ │      │
│                                   │ │  • DNS → dns-out │ │      │
│                                   │ └──┬──────────┬────┘ │      │
│                                   │    │          │      │      │
│                                   │  proxy      direct   │      │
│                                   │  outbound   outbound │      │
│                                   └──┬──────────┬────────┘      │
│                                      │          │               │
│                            ┌─────────┘          └──→ Physical NIC
│                            ▼                       (bypass TUN)  │
│                 ┌────────────────────────┐                     │
│                 │ SimpleProtocol Bridge   │                     │
│                 │ (SOCKS5 → Mux Tunnel)  │                     │
│                 │ 127.0.0.1:16080        │                     │
│                 └──────────┬─────────────┘                     │
│                            │ AES-256-GCM encrypted             │
│                            │ Mux multiplexed TCP               │
└────────────────────────────┼───────────────────────────────────┘
                             │
                             ▼
          ┌──────────────────────────────────────────────────┐
          │            SimpleProtocol Server                  │
          │                                                  │
          │  ┌───────────────────────────────────────────┐   │
          │  │ Listener (:23333)                         │   │
          │  │                                           │   │
          │  │  1. Handshake verification                │   │
          │  │     [nonce 32B][ts 8B][HMAC 32B][padding] │   │
          │  │                                           │   │
          │  │  2. HKDF-SHA256 key derivation            │   │
          │  │     c2s_key, s2c_key (AES-256-GCM)        │   │
          │  │                                           │   │
          │  │  3. Mux demultiplex                       │   │
          │  │     Stream 1 ──→ dial target-a:443        │   │
          │  │     Stream 2 ──→ dial target-b:80         │   │
          │  │     Stream N ──→ dial target-n:port       │   │
          │  └───────────────────────────────────────────┘   │
          └──────────────────────────────────────────────────┘
```

## Features

- SimpleProtocol node support
- Two routing modes: **Global** and **Smart Routing** (bypass domestic traffic)
- sing-box core embedded (via Libbox.xcframework)
- Local bridge converts sing-box SOCKS outbound into a SimpleProtocol encrypted tunnel
- Domain rule list and IP ranges are pre-generated and bundled statically
- Mux multiplexing: all proxy streams share a single encrypted TCP connection

## Build

- Open `SimpleProxyClient.xcodeproj` in Xcode
- Select your device or simulator
- Build & run

## Repository Layout

| Repository | Description |
|------------|-------------|
| [simple-proxy-client-ios](https://github.com/zUZWqEHF/simple-proxy-client-ios) | iOS client (this repo) |
| [simple-proxy-client-android](https://github.com/zUZWqEHF/simple-proxy-client-android) | Android client |
| [simple-proxy-server](https://github.com/zUZWqEHF/simple-proxy-server) | Server |

## License

MIT
