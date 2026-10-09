// MARK: - DeviceIcon.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The app icon, offered to control points through the UPnP device description.
//
// A DLNA server that advertises no icon shows up in a player's server list as a
// name next to whatever generic placeholder that player uses for "unknown device".
// The mechanism for fixing that is <iconList> in the device description: the server
// declares a handful of icons by size and format, and a control point that cares
// fetches whichever one suits its list.
//
// Two properties matter more than the icon itself, because a media server's job is
// to be found quickly and streamed from reliably:
//
//   • It must not cost anything to advertise. The description document grows by a
//     few lines of static XML; nothing is rendered, read, or allocated unless a
//     client actually asks for an icon, which most never do.
//   • It must not cost anything the second time. The rendered bytes are cached for
//     the life of the process, so a player that refetches on every browse — and some
//     do — is answered from memory.
//
// The sizes and formats are not free choices. The DLNA guidelines require a device
// that offers icons to offer these four (PNG and JPEG, each at 48x48 and 120x120),
// and firmware that looks for exactly one of them and gives up on not finding it is
// common enough that offering a single "best" icon is the option most likely to
// produce nothing at all.

import AppKit
import Foundation

@MainActor
enum DeviceIcon: Loggable {
    nonisolated static let logTag = "[DeviceIcon]"

    // MARK: - Advertised variants
    struct Variant: Sendable {
        let mimeType: String
        let pixels: Int
        // Bits per pixel, as the UPnP <depth> element reports it. PNG carries an
        // alpha channel here and JPEG does not, and a control point is entitled to
        // choose between the two on exactly that basis.
        let depth: Int
        let fileName: String

        var path: String { "\(UPnP.Path.iconPrefix)\(fileName)" }
        var isPNG: Bool { mimeType == "image/png" }
    }

    static let variants: [Variant] = [
        Variant(mimeType: "image/png",  pixels: 48,  depth: 32, fileName: "icon48.png"),
        Variant(mimeType: "image/png",  pixels: 120, depth: 32, fileName: "icon120.png"),
        Variant(mimeType: "image/jpeg", pixels: 48,  depth: 24, fileName: "icon48.jpg"),
        Variant(mimeType: "image/jpeg", pixels: 120, depth: 24, fileName: "icon120.jpg")
    ]

    // MARK: - Description fragment
    // Built once at load. The device description is regenerated per request — it has
    // to be, since URLBase depends on the interface the request arrived on — and this
    // is the part of it that never varies, so it is not rebuilt alongside.
    static let listXML: String = {
        let entries = variants.map { variant in
            """
                  <icon>
                    <mimetype>\(variant.mimeType)</mimetype>
                    <width>\(variant.pixels)</width>
                    <height>\(variant.pixels)</height>
                    <depth>\(variant.depth)</depth>
                    <url>\(variant.path)</url>
                  </icon>
            """
        }
        return "    <iconList>\n" + entries.joined(separator: "\n") + "\n    </iconList>"
    }()

    // MARK: - Serving
    private static var cache: [String: Data] = [:]

    // Returns the bytes and content type for a request path, or nil if the path is
    // not one of the advertised icons — so an unrecognized /icon/ URL falls through
    // to the router's ordinary 404 rather than being special-cased here.
    //
    // Best-effort by design. Every step that could fail (the app icon missing from
    // the bundle, a representation that will not encode) returns nil, and a control
    // point that gets nothing back simply shows its placeholder, exactly as it would
    // have if no icon had been advertised at all. Nothing about discovery, browsing,
    // or streaming depends on this succeeding.
    static func payload(forPath path: String) -> (data: Data, contentType: String)? {
        guard let variant = variants.first(where: { $0.path == path }) else { return nil }
        if let cached = cache[path] { return (cached, variant.mimeType) }
        guard let data = render(variant) else {
            Self.log("Could not render the \(variant.pixels)px \(variant.mimeType) "
                + "icon. The device description advertises it, so a client that asks "
                + "will get a 404 and fall back to its own placeholder.")
            return nil
        }
        cache[path] = data
        Self.log("Rendered and cached the \(variant.pixels)px \(variant.mimeType) icon "
            + "(\(data.count) bytes).")
        return (data, variant.mimeType)
    }

    private static func render(_ variant: Variant) -> Data? {
        let icon = NSImage(named: NSImage.applicationIconName)
        guard let icon else { return nil }

        let side = variant.pixels
        // unsafe: the initializer's planes parameter is a raw pointer, but passing nil
        // makes AppKit allocate and own the buffer, so no pointer is ever handled here.
        guard let bitmap = unsafe NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The rep is created at an explicit pixel size and then told its point size
        // matches, so the draw below is 1:1 regardless of the display's scale factor.
        // Without this a Retina context would render a 96px image into the 48px
        // buffer and the icon would arrive cropped to its top-left quarter.
        bitmap.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)

        // JPEG has no alpha, and an app icon is a rounded square with transparent
        // corners. Left to the encoder those corners become whatever the buffer
        // happened to contain; painted black first they become black, which is what
        // a player's list background almost always is. Chosen over white because a
        // dark corner reads as part of the artwork while a white one reads as a
        // rendering fault.
        if !variant.isPNG {
            NSColor.black.setFill()
            bounds.fill()
        }

        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return variant.isPNG
            ? bitmap.representation(using: .png, properties: [:])
            : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
