import Foundation

nonisolated enum NodeParser: Sendable {

    static func parse(_ uri: String) -> ProxyNode? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("ss://") {
            return parseShadowsocks(trimmed)
        } else if trimmed.lowercased().hasPrefix("simple://") {
            return parseSimpleProtocol(trimmed)
        }
        return nil
    }

    private static func parseShadowsocks(_ uri: String) -> ProxyNode? {
        var remaining = String(uri.dropFirst(5))

        var name = ""
        if let hashIndex = remaining.lastIndex(of: "#") {
            name = String(remaining[remaining.index(after: hashIndex)...])
            name = name.removingPercentEncoding ?? name
            remaining = String(remaining[..<hashIndex])
        }

        if let atIndex = remaining.lastIndex(of: "@") {
            let userInfo = String(remaining[..<atIndex])
            let hostPort = String(remaining[remaining.index(after: atIndex)...])

            guard let decoded = base64Decode(userInfo),
                  let colonIndex = decoded.firstIndex(of: ":") else { return nil }

            let method = String(decoded[..<colonIndex])
            let password = String(decoded[decoded.index(after: colonIndex)...])

            guard let (host, port) = parseHostPort(hostPort),
                  let cipher = ShadowsocksCipher(rawValue: method) else { return nil }

            if name.isEmpty { name = host }

            return ProxyNode(
                name: name, host: host, port: port,
                protocolType: .shadowsocks,
                ssCipher: cipher, ssPassword: password
            )
        }

        guard let decoded = base64Decode(remaining),
              let atIndex = decoded.lastIndex(of: "@") else { return nil }

        let userInfo = String(decoded[..<atIndex])
        let hostPort = String(decoded[decoded.index(after: atIndex)...])

        guard let colonIndex = userInfo.firstIndex(of: ":") else { return nil }
        let method = String(userInfo[..<colonIndex])
        let password = String(userInfo[userInfo.index(after: colonIndex)...])

        guard let (host, port) = parseHostPort(hostPort),
              let cipher = ShadowsocksCipher(rawValue: method) else { return nil }

        if name.isEmpty { name = host }

        return ProxyNode(
            name: name, host: host, port: port,
            protocolType: .shadowsocks,
            ssCipher: cipher, ssPassword: password
        )
    }

    private static func parseSimpleProtocol(_ uri: String) -> ProxyNode? {
        var remaining = String(uri.dropFirst(9))

        var name = ""
        if let hashIndex = remaining.lastIndex(of: "#") {
            name = String(remaining[remaining.index(after: hashIndex)...])
            name = name.removingPercentEncoding ?? name
            remaining = String(remaining[..<hashIndex])
        }

        guard let decoded = base64Decode(remaining) else { return nil }
        let parts = decoded.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let port = Int(parts[0]),
              let keyData = CryptoService.hexToData(parts[1]),
              keyData.count == 32 else { return nil }

        let host = parts[2]
        if name.isEmpty { name = host }

        return ProxyNode(
            name: name, host: host, port: port,
            protocolType: .simpleProtocol,
            spKey: parts[1]
        )
    }

    static func generateURI(for node: ProxyNode) -> String {
        switch node.protocolType {
        case .shadowsocks:
            guard let cipher = node.ssCipher, let password = node.ssPassword else { return "" }
            let userInfo = "\(cipher.rawValue):\(password)"
            let encoded = base64URLEncode(Data(userInfo.utf8))
            let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? node.name
            return "ss://\(encoded)@\(node.host):\(node.port)#\(encodedName)"
        case .simpleProtocol:
            guard let key = node.spKey else { return "" }
            let payload = "\(node.port):\(key):\(node.host)"
            let encoded = base64URLEncode(Data(payload.utf8))
            let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? node.name
            return "simple://\(encoded)#\(encodedName)"
        }
    }

    private static func base64Decode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseHostPort(_ string: String) -> (String, Int)? {
        if string.hasPrefix("[") {
            guard let closeBracket = string.firstIndex(of: "]") else { return nil }
            let host = String(string[string.index(after: string.startIndex)..<closeBracket])
            let afterBracket = string.index(after: closeBracket)
            guard afterBracket < string.endIndex,
                  string[afterBracket] == ":",
                  let port = Int(string[string.index(after: afterBracket)...]) else { return nil }
            return (host, port)
        }

        guard let colonIndex = string.lastIndex(of: ":"),
              let port = Int(string[string.index(after: colonIndex)...]) else { return nil }
        return (String(string[..<colonIndex]), port)
    }
}
