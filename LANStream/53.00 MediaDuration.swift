// MARK: - MediaDuration.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reads a video file's running time out of its container header.
//
// Why this exists: res@duration is the one piece of metadata a DLNA player cannot
// derive for itself before it opens the stream, and without it a browse list shows
// no running times at all. Everything else in a res element — size, MIME type, the
// seek flags — is either known from the filesystem or fixed per format. The
// duration is inside the file.
//
// Why it is written by hand rather than handed to AVFoundation: AVAsset does not
// open Matroska, which is the overwhelming majority of what this server publishes.
// Reaching for it would mean durations for the mp4 minority and nothing for the
// rest, which is the wrong side of the trade.
//
// Every entry point here is best-effort and returns nil rather than throwing. A
// duration that cannot be read is a res element without the attribute, which is
// exactly what was published before this file existed — never a skipped file and
// never a failed scan. It is also strictly bounded: it reads element headers and
// seeks past payloads rather than scanning, gives up after a fixed number of
// elements, and never reads more than a few kilobytes from a file that may be
// thirty gigabytes on a spinning external drive.

import Foundation

enum MediaDuration {

    // Upper bound on how many container elements will be walked before giving up.
    // A well-formed file reaches what this needs within the first handful; a
    // malformed or hostile one must not be able to turn a scan into a long walk.
    private static let maximumElements = 512

    // MARK: - Entry point
    // Returns the running time in seconds, or nil when it cannot be determined.
    static func seconds(forFileAt url: URL) -> Double? {
        guard let handle = FileHandle(forReadingAtPath: url.path(percentEncoded: false))
        else { return nil }
        defer { try? handle.close() }

        let reader = ByteReader(handle: handle)
        let value: Double?
        switch url.pathExtension.lowercased() {
        case "mkv":
            value = matroskaDuration(reader)
        case "mp4", "m4v", "mov":
            value = isoBMFFDuration(reader)
        default:
            value = nil
        }

        // A duration of zero or less is not a duration; publishing 0:00:00 is worse
        // than publishing nothing, because a player renders it as a real answer.
        //
        // The ceiling matters as much as the floor. Both header fields are raw
        // numbers straight off the disk — an EBML float can hold 1e300, an mvhd
        // duration 2^64 over a timescale of 1 — and format() converts to Int, which
        // TRAPS for anything at or beyond 2^63. One corrupt or hostile file in a
        // shared folder would then take the whole server down on the first Browse
        // of its folder. Nothing real runs anywhere near this long.
        guard let value, value > 0, value.isFinite,
              value <= maximumPlausibleSeconds else { return nil }
        return value
    }

    // One hundred thousand hours: far past any real recording, far below where the
    // integer arithmetic in format() stops being safe.
    private static let maximumPlausibleSeconds: Double = 100_000 * 3600

    // MARK: - Formatting
    // UPnP wants H+:MM:SS[.F+]. Hours are not zero-padded and are not capped at 24 —
    // the grammar is "one or more digits" — while minutes and seconds always take
    // two.
    static func format(_ seconds: Double) -> String {
        // Clamped as well as validated upstream: Int(_:) traps on a non-finite or
        // out-of-range Double, and this runs inside a Browse response.
        let seconds = seconds.isFinite
            ? min(max(seconds, 0), maximumPlausibleSeconds)
            : 0
        let total = Int(seconds.rounded(.down))
        let milliseconds = Int(((seconds - Double(total)) * 1000).rounded())
        // Rounding the fraction up to a full second must carry into the seconds
        // field rather than emitting ".1000".
        let carry = milliseconds / 1000
        let hours = (total + carry) / 3600
        let minutes = ((total + carry) % 3600) / 60
        let secs = (total + carry) % 60
        return "\(hours):\(minutes.zeroPadded(2)):\(secs.zeroPadded(2))."
            + (milliseconds % 1000).zeroPadded(3)
    }

    // MARK: - Matroska / WebM
    // Duration lives in the Info element as a float expressed in TimecodeScale
    // units, where TimecodeScale is nanoseconds per unit and defaults to 1,000,000
    // (that is, milliseconds).
    private enum EBML {
        static let header: UInt64 = 0x1A45_DFA3
        static let segment: UInt64 = 0x1853_8067
        static let info: UInt64 = 0x1549_A966
        static let timecodeScale: UInt64 = 0x2AD7_B1
        static let duration: UInt64 = 0x4489
        static let cluster: UInt64 = 0x1F43_B675
    }

    private static func matroskaDuration(_ reader: ByteReader) -> Double? {
        // The EBML header comes first and is skipped wholesale; nothing in it is
        // needed here.
        guard let first = reader.readElement(), first.id == EBML.header else { return nil }
        reader.skip(first.size)

        guard let segment = reader.readElement(), segment.id == EBML.segment else { return nil }
        // Segment size is routinely 'unknown' in files written in one pass, so the
        // walk below is bounded by element count and by hitting the first Cluster
        // rather than by the segment's declared length.
        let segmentEnd = segment.hasKnownSize
            ? reader.offset &+ segment.size
            : UInt64.max

        var walked = 0
        while reader.offset < segmentEnd, walked < maximumElements {
            walked += 1
            guard let element = reader.readElement() else { return nil }

            if element.id == EBML.info {
                return parseMatroskaInfo(reader, size: element.size)
            }
            // Clusters are the media payload. Info is written before them in every
            // muxer in circulation, so reaching one means it is not coming, and
            // continuing would seek through gigabytes of frames to prove it.
            if element.id == EBML.cluster { return nil }
            guard element.hasKnownSize else { return nil }
            reader.skip(element.size)
        }
        return nil
    }

    private static func parseMatroskaInfo(_ reader: ByteReader, size: UInt64) -> Double? {
        let end = reader.offset &+ size
        // Nanoseconds per timecode unit. The Matroska default when absent.
        var timecodeScale: Double = 1_000_000
        var rawDuration: Double?

        var walked = 0
        while reader.offset < end, walked < maximumElements {
            walked += 1
            guard let element = reader.readElement(), element.hasKnownSize else { break }

            switch element.id {
            case EBML.timecodeScale:
                if let value = reader.readUnsignedInteger(length: element.size), value > 0 {
                    timecodeScale = Double(value)
                }
            case EBML.duration:
                rawDuration = reader.readFloat(length: element.size)
            default:
                reader.skip(element.size)
            }
        }

        guard let rawDuration else { return nil }
        return rawDuration * timecodeScale / 1_000_000_000
    }

    // MARK: - MP4 / QuickTime
    // Duration is in the movie header box, as a count of units at the movie
    // timescale. 'moov' is at the end of any file that was not written for
    // progressive download, so the top-level boxes are skipped through by size
    // rather than assumed to be in a helpful order.
    private static func isoBMFFDuration(_ reader: ByteReader) -> Double? {
        guard let moov = findBox(reader, type: "moov", within: UInt64.max) else { return nil }
        guard let mvhd = findBox(reader, type: "mvhd", within: reader.offset &+ moov) else {
            return nil
        }
        _ = mvhd

        guard let versionAndFlags = reader.readUnsignedInteger(length: 4) else { return nil }
        let version = versionAndFlags >> 24

        let timescale: UInt64?
        let duration: UInt64?
        if version == 1 {
            reader.skip(16) // 64-bit creation and modification times
            timescale = reader.readUnsignedInteger(length: 4)
            duration = reader.readUnsignedInteger(length: 8)
        } else {
            reader.skip(8)  // 32-bit creation and modification times
            timescale = reader.readUnsignedInteger(length: 4)
            duration = reader.readUnsignedInteger(length: 4)
        }

        guard let timescale, timescale > 0, let duration else { return nil }
        // 0xFFFFFFFF is the documented "unknown duration" sentinel for the 32-bit
        // field and must not be divided into a running time of 49 days.
        if version != 1 && duration == 0xFFFF_FFFF { return nil }
        return Double(duration) / Double(timescale)
    }

    // Walks sibling boxes at the current offset, leaving the reader positioned just
    // inside the matching box. Returns that box's payload length.
    private static func findBox(_ reader: ByteReader, type: String, within end: UInt64) -> UInt64? {
        var walked = 0
        while reader.offset < end, walked < maximumElements {
            walked += 1
            guard let size32 = reader.readUnsignedInteger(length: 4),
                  let rawType = reader.readBytes(4) else { return nil }

            var payload: UInt64
            switch size32 {
            case 0:
                // Extends to end of file; its payload length is unknowable here, but
                // a container box declared this way still starts right where we are.
                payload = UInt64.max
            case 1:
                guard let size64 = reader.readUnsignedInteger(length: 8),
                      size64 >= 16 else { return nil }
                payload = size64 - 16
            default:
                guard size32 >= 8 else { return nil }
                payload = size32 - 8
            }

            if String(decoding: rawType, as: UTF8.self) == type { return payload }
            if payload == UInt64.max { return nil }
            reader.skip(payload)
        }
        return nil
    }
}

// MARK: - ByteReader
// A cursor over a file that reads forward in small pieces and seeks past anything
// it does not need. Deliberately not a buffered whole-file reader: the files this
// walks are tens of gigabytes and everything of interest is in their first few
// kilobytes or, for a non-faststart mp4, their last few.
private final class ByteReader {
    private let handle: FileHandle
    private(set) var offset: UInt64 = 0

    init(handle: FileHandle) { self.handle = handle }

    func readBytes(_ count: Int) -> [UInt8]? {
        guard count > 0, count <= 8192 else { return nil }
        guard let data = try? handle.read(upToCount: count), data.count == count else {
            return nil
        }
        offset &+= UInt64(count)
        return Array(data)
    }

    func skip(_ count: UInt64) {
        guard count > 0 else { return }
        let target = offset &+ count
        // Seeking past the end is not an error on its own; the next read simply
        // returns nothing and the walk stops.
        try? handle.seek(toOffset: target)
        offset = target
    }

    func readUnsignedInteger(length: UInt64) -> UInt64? {
        guard length >= 1, length <= 8, let bytes = readBytes(Int(length)) else { return nil }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    // EBML floats are 4 or 8 bytes, big-endian IEEE 754. A zero length is legal and
    // means zero, which the caller rejects as not-a-duration.
    func readFloat(length: UInt64) -> Double? {
        switch length {
        case 0: return 0
        case 4:
            guard let raw = readUnsignedInteger(length: 4) else { return nil }
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8:
            guard let raw = readUnsignedInteger(length: 8) else { return nil }
            return Double(bitPattern: raw)
        default:
            skip(length)
            return nil
        }
    }

    // MARK: EBML variable-length quantities
    struct Element {
        let id: UInt64
        let size: UInt64
        let hasKnownSize: Bool
    }

    func readElement() -> Element? {
        guard let id = readElementID(), let size = readDataSize() else { return nil }
        return Element(id: id, size: size.value, hasKnownSize: size.isKnown)
    }

    // An element ID keeps its length-marker bit: the marker is part of the ID's
    // canonical value, which is why Segment is 0x18538067 and not 0x08538067.
    private func readElementID() -> UInt64? {
        guard let first = readBytes(1)?.first, first != 0 else { return nil }
        let extra = 7 - first.bitWidthOfHighestSetBit
        guard extra <= 3 else { return nil }
        var value = UInt64(first)
        if extra > 0 {
            guard let rest = readBytes(extra) else { return nil }
            for byte in rest { value = (value << 8) | UInt64(byte) }
        }
        return value
    }

    // A data size clears its marker bit, and an all-ones payload means the size is
    // unknown — legal for the Segment of a file written in a single pass.
    private func readDataSize() -> (value: UInt64, isKnown: Bool)? {
        guard let first = readBytes(1)?.first, first != 0 else { return nil }
        let extra = 7 - first.bitWidthOfHighestSetBit
        guard extra <= 7 else { return nil }
        var value = UInt64(first & ~(1 << UInt8(7 - extra)))
        var allOnes = value == (1 << UInt64(7 - extra)) - 1
        if extra > 0 {
            guard let rest = readBytes(extra) else { return nil }
            for byte in rest {
                value = (value << 8) | UInt64(byte)
                if byte != 0xFF { allOnes = false }
            }
        }
        return (value, !allOnes)
    }
}

private extension UInt8 {
    // Index of the highest set bit, 0-based from the least significant end.
    var bitWidthOfHighestSetBit: Int { 7 - leadingZeroBitCount }
}
