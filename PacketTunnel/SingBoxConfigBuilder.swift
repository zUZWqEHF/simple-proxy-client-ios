// SingBoxConfigBuilder.swift – Generates sing-box JSON configuration
// Mirrors Android's SingBoxConfigBuilder.kt (Global + BypassChina)

import Foundation

enum SingBoxConfigBuilder {

    /// Build a sing-box JSON config.
    ///
    /// - `routingMode`: `.global` routes all traffic through proxy;
    ///   `.bypassChina` uses rule_set files (GFW domains → proxy, China IPs → direct).
    /// - `workDir`: directory where rule_set JSON files are written (required for BypassChina).
    /// - `bridgePort`: local SOCKS5 port of the SimpleProtocol bridge.
    static func build(
        routingMode: String = "global",
        bridgePort: UInt16 = 16080,
        workDir: URL? = nil
    ) -> String {
        let isBypass = (routingMode == "bypassChina")

        // Write rule_set files for BypassChina mode
        if isBypass, let workDir = workDir {
            writeGfwRuleSet(to: workDir)
            writeChinaIpRuleSet(to: workDir)
        }

        var config: [String: Any] = [:]

        // ── Log ──
        config["log"] = [
            "level": "warn",
            "timestamp": true
        ]

        // ── DNS ──
        let dnsServers: [[String: Any]] = [
            [
                "tag": "remote-dns",
                "address": "tcp://8.8.8.8",
                "detour": "proxy"
            ],
            [
                "tag": "direct-dns",
                "address": "223.5.5.5",
                "detour": "direct"
            ]
        ]
        _ = dnsServers  // suppress warning

        var dnsRules: [[String: Any]]
        if isBypass {
            // GFW domains → remote DNS (through proxy to avoid poisoning)
            dnsRules = [
                [
                    "rule_set": ["gfw-domains"],
                    "server": "remote-dns"
                ]
            ]
        } else {
            // Global: resolve everything through remote DNS via proxy
            dnsRules = [
                [
                    "outbound": ["any"],
                    "server": "direct-dns"   // bootstrap DNS for proxy server resolution
                ]
            ]
        }

        config["dns"] = [
            "servers": dnsServers,
            "rules": dnsRules,
            "strategy": "prefer_ipv4",
            "final": isBypass ? "direct-dns" : "remote-dns",
            "independent_cache": true
        ]

        // ── Inbounds ──
        config["inbounds"] = [
            [
                "type": "tun",
                "tag": "tun-in",
                "inet4_address": "172.19.0.1/30",
                "mtu": 9000,
                "auto_route": true,
                "sniff": true,
                "sniff_override_destination": true
            ]
        ]

        // ── Outbounds ──
        config["outbounds"] = [
            [
                "type": "socks",
                "tag": "proxy",
                "server": "127.0.0.1",
                "server_port": Int(bridgePort)
            ],
            [
                "type": "direct",
                "tag": "direct"
            ],
            [
                "type": "block",
                "tag": "block"
            ],
            [
                "type": "dns",
                "tag": "dns-out"
            ]
        ]

        // ── Route ──
        var routeRules: [[String: Any]] = [
            [
                "protocol": "dns",
                "outbound": "dns-out"
            ]
        ]
        if isBypass {
            routeRules.append([
                "rule_set": ["gfw-domains"],
                "outbound": "proxy"
            ])
            routeRules.append([
                "rule_set": ["china-ips"],
                "outbound": "direct"
            ])
        }

        var route: [String: Any] = [
            "rules": routeRules,
            "final": isBypass ? "direct" : "proxy",
            "auto_detect_interface": true
        ]

        if isBypass, let workDir = workDir {
            route["rule_set"] = [
                [
                    "tag": "gfw-domains",
                    "type": "local",
                    "format": "source",
                    "path": workDir.appendingPathComponent("gfw-domains.json").path
                ],
                [
                    "tag": "china-ips",
                    "type": "local",
                    "format": "source",
                    "path": workDir.appendingPathComponent("china-ips.json").path
                ]
            ]
        }

        config["route"] = route

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            fatalError("Failed to serialize sing-box config")
        }
        return json
    }

    /// Legacy helper for backward compatibility.
    static func buildGlobalConfig(bridgePort: UInt16 = 16080) -> String {
        build(routingMode: "global", bridgePort: bridgePort)
    }

    // MARK: - Rule-set file generation

    /// Write GFW domain rule-set in sing-box "source" format.
    private static func writeGfwRuleSet(to workDir: URL) {
        let domains = GeneratedGfwDomains.domains
        var parts: [String] = []
        for domain in domains {
            let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !d.isEmpty else { continue }
            parts.append("\"\(d)\"")
        }
        let json = "{\"version\":2,\"rules\":[{\"domain_suffix\":[\(parts.joined(separator: ","))]}]}"
        let url = workDir.appendingPathComponent("gfw-domains.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write China IP CIDR rule-set in sing-box "source" format.
    private static func writeChinaIpRuleSet(to workDir: URL) {
        let cidrs = ChinaIpRanges.allCidrs()
        var parts: [String] = []
        for cidr in cidrs {
            parts.append("\"\(cidr)\"")
        }
        let json = "{\"version\":2,\"rules\":[{\"ip_cidr\":[\(parts.joined(separator: ","))]}]}"
        let url = workDir.appendingPathComponent("china-ips.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }
}
