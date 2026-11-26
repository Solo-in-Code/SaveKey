// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal XML element tree. Used to read/write the KDBX XML payload while
/// preserving elements this app does not understand.
public final class XNode: @unchecked Sendable {
    public var name: String
    public var attributes: [(String, String)]
    public var text: String
    public var children: [XNode]

    public init(_ name: String, text: String = "", attributes: [(String, String)] = [], children: [XNode] = []) {
        self.name = name
        self.text = text
        self.attributes = attributes
        self.children = children
    }

    public func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XNode] { children.filter { $0.name == name } }
    public func attribute(_ name: String) -> String? { attributes.first { $0.0 == name }?.1 }

    public func setAttribute(_ name: String, _ value: String?) {
        attributes.removeAll { $0.0 == name }
        if let value { attributes.append((name, value)) }
    }

    @discardableResult
    func add(_ name: String, _ text: String) -> XNode {
        let n = XNode(name, text: text)
        children.append(n)
        return n
    }

    func add(_ node: XNode) { children.append(node) }

    public func deepCopy() -> XNode {
        XNode(name, text: text, attributes: attributes, children: children.map { $0.deepCopy() })
    }
}

enum XMLTree {
    /// Parses XML. Values marked `Protected="True"` are decrypted with `protectedStream`
    /// in document order, which is how KeePass encrypts them.
    static func parse(_ data: Data, protectedStream: KeystreamCipher?) throws -> XNode {
        let delegate = ParserDelegate(stream: protectedStream)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.error { throw error }
        guard ok, let root = delegate.root else {
            throw KDBXError.xmlParseFailure(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        return root
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let stream: KeystreamCipher?
        var stack: [XNode] = []
        var textStack: [String] = []
        var root: XNode?
        var error: Error?

        init(stream: KeystreamCipher?) { self.stream = stream }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            // Keep a stable attribute order for round-tripping.
            let attrs = attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            let node = XNode(elementName, attributes: attrs)
            stack.last?.children.append(node)
            stack.append(node)
            textStack.append("")
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !textStack.isEmpty else { return }
            textStack[textStack.count - 1] += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !textStack.isEmpty else { return }
            textStack[textStack.count - 1] += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            let text = textStack.popLast() ?? ""
            if node.children.isEmpty {
                node.text = text
                if let p = node.attribute("Protected"), p.caseInsensitiveCompare("true") == .orderedSame {
                    decryptProtected(node)
                }
            }
            if stack.isEmpty { root = node }
        }

        private func decryptProtected(_ node: XNode) {
            guard let stream else { return }
            let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cipherText = Data(base64Encoded: trimmed) else {
                if !trimmed.isEmpty { error = KDBXError.corrupted("invalid protected value") }
                return
            }
            var bytes = [UInt8](cipherText)
            stream.xor(&bytes)
            node.text = String(decoding: bytes, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil { error = KDBXError.xmlParseFailure(parseError.localizedDescription) }
        }
    }

    // MARK: - Serialisation

    static func serialize(_ root: XNode, protectedStream: KeystreamCipher?) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n"
        out.reserveCapacity(64 * 1024)
        write(root, depth: 0, into: &out, stream: protectedStream)
        return Data(out.utf8)
    }

    private static func write(_ node: XNode, depth: Int, into out: inout String, stream: KeystreamCipher?) {
        let indent = String(repeating: "\t", count: depth)
        out += indent + "<" + node.name
        for (k, v) in node.attributes { out += " \(k)=\"\(escape(v, attribute: true))\"" }
        if !node.children.isEmpty {
            out += ">\n"
            for c in node.children { write(c, depth: depth + 1, into: &out, stream: stream) }
            out += indent + "</" + node.name + ">\n"
            return
        }
        var text = node.text
        if let p = node.attribute("Protected"), p == "True", let stream {
            var bytes = [UInt8](text.utf8)
            stream.xor(&bytes)
            text = Data(bytes).base64EncodedString()
        }
        if text.isEmpty {
            out += " />\n"
        } else {
            out += ">" + escape(text, attribute: false) + "</" + node.name + ">\n"
        }
    }

    static func escape(_ s: String, attribute: Bool) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"" where attribute: r += "&quot;"
            case "\r": r += "&#xD;"
            case "\n" where attribute: r += "&#xA;"
            case "\t" where attribute: r += "&#x9;"
            default:
                let v = scalar.value
                // Drop characters that are not allowed in XML 1.0.
                let valid = v == 0x9 || v == 0xA || (v >= 0x20 && v <= 0xD7FF) ||
                    (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
                if valid { r.unicodeScalars.append(scalar) }
            }
        }
        return r
    }
}
