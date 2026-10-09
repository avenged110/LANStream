// MARK: - SOAP.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Minimal SOAP request parsing and response construction for UPnP control.
//
// UPnP uses a very small, rigid subset of SOAP: a single action element inside
// the Body, whose direct children are the arguments as plain text. Parsing is
// done with Foundation's XMLParser rather than by pattern matching on strings —
// namespace prefixes vary between control points, and a regex-based parser that
// works with one client tends to fail on the next.

import Foundation

// MARK: - SOAPRequest
struct SOAPRequest: Sendable {
    // Local name of the action element, e.g. "Browse". The element's namespace (the
    // service type) is not kept: the control URL the request arrived on already
    // decides which service answers it.
    let action: String
    // Argument name → text content.
    let arguments: [String: String]

    func argument(_ name: String) -> String? { arguments[name] }

    func intArgument(_ name: String, default defaultValue: Int) -> Int {
        guard let raw = arguments[name], let value = Int(raw) else { return defaultValue }
        return value
    }
}

// MARK: - SOAPParser
enum SOAPParser {

    // Parses a SOAP envelope body. Returns nil when the document is malformed or
    // contains no recognizable action element.
    static func parse(_ data: Data) -> SOAPRequest? {
        let delegate = EnvelopeParserDelegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        // Explicit, though both already default to false. This parser is fed a body
        // from any device that can reach the control endpoint, and the two switches
        // below are the difference between a SOAP parser and a file-disclosure and
        // SSRF primitive: an external entity pointing at file:///etc/passwd or at an
        // internal http:// address would otherwise be fetched by this process and
        // could be reflected back in a fault or a Browse echo. Verified refused
        // against a live build; pinned here so a future Foundation default cannot
        // quietly change the answer.
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        // XMLParser holds its delegate unowned(unsafe), so the parse runs inside an
        // explicit lifetime extension rather than relying on the later reads of
        // `delegate` to keep it alive.
        guard withExtendedLifetime(delegate, { parser.parse() }), let action = delegate.actionName else { return nil }
        return SOAPRequest(action: action, arguments: delegate.arguments)
    }

    // XMLParser's delegate protocol is class-bound and its callbacks are delivered
    // synchronously on the thread that called parse(), so this type never escapes
    // the calling context. It is not Sendable and does not need to be.
    private final class EnvelopeParserDelegate: NSObject, XMLParserDelegate {

        private(set) var actionName: String?
        private(set) var arguments: [String: String] = [:]

        // Depth relative to the Body element: 1 is the action, 2 is an argument.
        private var depthBelowBody = -1
        private var currentArgumentName: String?
        private var currentText = ""

        private static let soapEnvelopeNamespace = "http://schemas.xmlsoap.org/soap/envelope/"

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName: String?,
                    attributes attributeDict: [String: String]) {

            // Accept the Body element by local name regardless of prefix; some
            // control points use "s:", others "SOAP-ENV:" or a default namespace.
            if depthBelowBody < 0 {
                if elementName == "Body" &&
                    (namespaceURI == Self.soapEnvelopeNamespace || namespaceURI == nil) {
                    depthBelowBody = 0
                }
                return
            }

            depthBelowBody += 1
            switch depthBelowBody {
            case 1:
                actionName = elementName
            case 2:
                currentArgumentName = elementName
                currentText = ""
            default:
                // UPnP arguments are flat text; anything deeper is ignored rather
                // than treated as an error, so an unexpected extension element from
                // a chatty control point cannot fail the whole request.
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depthBelowBody == 2 else { return }
            currentText += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName: String?) {
            guard depthBelowBody >= 0 else { return }

            if depthBelowBody == 2, let name = currentArgumentName {
                arguments[name] = currentText
                currentArgumentName = nil
                currentText = ""
            }
            depthBelowBody -= 1
        }
    }
}

// MARK: - SOAPResponse
enum SOAPResponse {

    // Wraps a set of already-serialized output arguments in a SOAP envelope.
    static func envelope(action: String,
                         serviceType: String,
                         arguments: [(name: String, value: String)]) -> String {
        let body = arguments.map { argument in
            "<\(argument.name)>\(argument.value)</\(argument.name)>"
        }.joined()

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body>\
        <u:\(action)Response xmlns:u="\(serviceType)">\(body)</u:\(action)Response>\
        </s:Body>\
        </s:Envelope>
        """
    }

    // MARK: - Faults
    // UPnP faults are returned with HTTP status 500 and a UPnPError payload. A bare
    // HTTP error without this body causes some control points to drop the device
    // entirely instead of just failing the one action.
    enum UPnPError: Int {
        case invalidAction         = 401
        case invalidArgs           = 402
        case noSuchObject          = 701
        case unsupportedBrowseFlag = 710

        var description: String {
            switch self {
            case .invalidAction:         return "Invalid Action"
            case .invalidArgs:           return "Invalid Args"
            case .noSuchObject:          return "No such object"
            case .unsupportedBrowseFlag: return "Unsupported or invalid browse flag"
            }
        }
    }

    static func fault(_ error: UPnPError) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body>\
        <s:Fault>\
        <faultcode>s:Client</faultcode>\
        <faultstring>UPnPError</faultstring>\
        <detail>\
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">\
        <errorCode>\(error.rawValue)</errorCode>\
        <errorDescription>\(XML.escape(error.description))</errorDescription>\
        </UPnPError>\
        </detail>\
        </s:Fault>\
        </s:Body>\
        </s:Envelope>
        """
    }
}
