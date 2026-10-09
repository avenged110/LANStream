// MARK: - UPnPDescriptions.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Static UPnP/DLNA description documents and protocol constants.
//
// Everything here is fixed text apart from the device descriptor, which is
// parameterized by UDN, friendly name, and the base URL the client reached us on.
// Keeping these as string constants rather than generating XML through a builder
// is deliberate: these documents never vary structurally, and a literal is far
// easier to compare against the UPnP Device Architecture spec during debugging.

import Foundation

enum UPnP {

    // MARK: - Service and device type URNs
    static let mediaServerDeviceType   = "urn:schemas-upnp-org:device:MediaServer:1"
    static let contentDirectoryType    = "urn:schemas-upnp-org:service:ContentDirectory:1"
    static let connectionManagerType   = "urn:schemas-upnp-org:service:ConnectionManager:1"
    static let rootDeviceType          = "upnp:rootdevice"

    // MARK: - HTTP resource paths
    enum Path {
        static let deviceDescription    = "/description.xml"
        static let contentDirectorySCPD = "/ContentDirectory.xml"
        static let connectionManagerSCPD = "/ConnectionManager.xml"
        static let contentDirectoryControl = "/control/ContentDirectory"
        static let connectionManagerControl = "/control/ConnectionManager"
        static let contentDirectoryEvent = "/event/ContentDirectory"
        static let connectionManagerEvent = "/event/ConnectionManager"
        // Media resources are served as /media/<objectID>.mkv. The extension is
        // cosmetic but some players use it as a format hint before reading headers.
        static let mediaPrefix = "/media/"
        // Device icons, advertised in <iconList>. See DeviceIcon.swift.
        static let iconPrefix = "/icon/"
    }

    // MARK: - DLNA content features
    // Advertised on every media response and in DIDL protocolInfo.
    //
    //   DLNA.ORG_OP=01      → byte-range seek supported, time-based seek not.
    //                         This is the flag that gives the Oppo a working seek
    //                         bar; without it the player assumes the stream cannot
    //                         be repositioned and disables scrubbing entirely.
    //   DLNA.ORG_CI=0       → content is not transcoded (delivered as authored).
    //   DLNA.ORG_FLAGS      → streaming mode, background transfer permitted,
    //                         full clear-text byte-seek available.
    static let mkvMIMEType = "video/x-matroska"
    static let contentFeatures =
        "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    // MARK: - Container formats
    // The MIME type a file is served and advertised under, chosen by extension.
    //
    // This is per-file rather than per-server because the two families do not share
    // a type: a player handed video/x-matroska for an .mp4 will either refuse it or
    // — worse on some firmware — accept it, fail to demux, and report a corrupt
    // file. .mov is grouped with MP4 because QuickTime is the container MP4 was
    // derived from and players that handle one generally handle the other, but it
    // keeps its own registered type rather than being flattened into video/mp4.
    static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        default:           return mkvMIMEType
        }
    }

    // Every type this server can ever emit, for the GetProtocolInfo response.
    static let allMediaMIMETypes = [mkvMIMEType, "video/mp4", "video/quicktime"]

    // Neither MKV nor bare MP4 has an assigned DLNA profile name that applies to
    // arbitrary content, so protocolInfo carries a wildcard fourth field. Players
    // that filter strictly on profile names would reject a fabricated one; the
    // wildcard is both correct and maximally compatible.
    static func protocolInfo(forMIMEType mimeType: String) -> String {
        "http-get:*:\(mimeType):*"
    }

    // Returned by ConnectionManager#GetProtocolInfo. Some firmware cross-checks
    // every res@protocolInfo in a Browse result against this list and hides items
    // that do not appear in it, so the two must stay in agreement.
    //
    // Deliberately NOT narrowed to the formats currently permitted. This list says
    // what the server is capable of delivering, and a control point that caches it
    // once at discovery would otherwise be left holding a stale, too-narrow list
    // after the user widens the setting — hiding items it had already been told
    // about. Advertising a type no file currently uses costs nothing.
    static let sourceProtocolInfo = allMediaMIMETypes
        .map { protocolInfo(forMIMEType: $0) }
        .joined(separator: ",")

    // MARK: - Device description
    // 'baseURL' must be the exact scheme://host:port the client used to reach us.
    // Control points resolve the relative SCPD/control/event URLs below against the
    // URLBase (or against the request URL), and a mismatch — for example advertising
    // a different interface's address than the one the request arrived on — is a
    // classic cause of "device appears but browsing returns nothing" on multi-homed
    // machines. HTTPListener therefore derives this per request.
    // 'iconList' is the <iconList> element, passed in rather than referenced
    // directly so this file stays what its header says it is — static text — and so
    // a caller with no icons to offer can supply an empty string.
    //
    // There is deliberately no <presentationURL>. It is optional, and it means "the
    // HTML page a user can open to administer this device" — this server has no such
    // page. It previously pointed at the description document, which is the one thing
    // it definitely must not be: a control point offering the user a link to their
    // device's web page would have handed them raw XML. Omitting it is both correct
    // and what a control point expects from a device with no presentation.
    static func deviceDescription(udn: String,
                                  friendlyName: String,
                                  baseURL: String,
                                  serialNumber: String,
                                  iconList: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
          <specVersion>
            <major>1</major>
            <minor>0</minor>
          </specVersion>
          <URLBase>\(XML.escape(baseURL))</URLBase>
          <device>
            <deviceType>\(mediaServerDeviceType)</deviceType>
            <dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMS-1.50</dlna:X_DLNADOC>
            <friendlyName>\(XML.escape(friendlyName))</friendlyName>
            <manufacturer>avenged110</manufacturer>
            <manufacturerURL>http://localhost/</manufacturerURL>
            <modelDescription>LAN Stream DLNA Media Server</modelDescription>
            <modelName>LAN Stream</modelName>
            <modelNumber>1.0</modelNumber>
            <modelURL>http://localhost/</modelURL>
            <serialNumber>\(XML.escape(serialNumber))</serialNumber>
            <UDN>uuid:\(XML.escape(udn))</UDN>
        \(iconList)
            <serviceList>
              <service>
                <serviceType>\(contentDirectoryType)</serviceType>
                <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
                <SCPDURL>\(Path.contentDirectorySCPD)</SCPDURL>
                <controlURL>\(Path.contentDirectoryControl)</controlURL>
                <eventSubURL>\(Path.contentDirectoryEvent)</eventSubURL>
              </service>
              <service>
                <serviceType>\(connectionManagerType)</serviceType>
                <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                <SCPDURL>\(Path.connectionManagerSCPD)</SCPDURL>
                <controlURL>\(Path.connectionManagerControl)</controlURL>
                <eventSubURL>\(Path.connectionManagerEvent)</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }

    // MARK: - ContentDirectory SCPD
    // Declares only the actions LAN Stream implements. A control point is entitled
    // to call anything listed here, so the list is kept to exactly what is supported
    // rather than padded out with actions that would return a fault.
    static let contentDirectorySCPD = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion>
        <major>1</major>
        <minor>0</minor>
      </specVersion>
      <actionList>
        <action>
          <name>Browse</name>
          <argumentList>
            <argument><name>ObjectID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument>
            <argument><name>BrowseFlag</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument>
            <argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument>
            <argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument>
            <argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
            <argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument>
            <argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument>
            <argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
            <argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
            <argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument>
          </argumentList>
        </action>
        <action>
          <name>GetSearchCapabilities</name>
          <argumentList>
            <argument><name>SearchCaps</name><direction>out</direction><relatedStateVariable>SearchCapabilities</relatedStateVariable></argument>
          </argumentList>
        </action>
        <action>
          <name>GetSortCapabilities</name>
          <argumentList>
            <argument><name>SortCaps</name><direction>out</direction><relatedStateVariable>SortCapabilities</relatedStateVariable></argument>
          </argumentList>
        </action>
        <action>
          <name>GetSystemUpdateID</name>
          <argumentList>
            <argument><name>Id</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument>
          </argumentList>
        </action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_BrowseFlag</name><dataType>string</dataType>
          <allowedValueList>
            <allowedValue>BrowseMetadata</allowedValue>
            <allowedValue>BrowseDirectChildren</allowedValue>
          </allowedValueList>
        </stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Filter</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_SortCriteria</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Index</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Count</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_UpdateID</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>SearchCapabilities</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>SortCapabilities</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>SystemUpdateID</name><dataType>ui4</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    // MARK: - ConnectionManager SCPD
    static let connectionManagerSCPD = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion>
        <major>1</major>
        <minor>0</minor>
      </specVersion>
      <actionList>
        <action>
          <name>GetProtocolInfo</name>
          <argumentList>
            <argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
            <argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
          </argumentList>
        </action>
        <action>
          <name>GetCurrentConnectionIDs</name>
          <argumentList>
            <argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
          </argumentList>
        </action>
        <action>
          <name>GetCurrentConnectionInfo</name>
          <argumentList>
            <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
            <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
            <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
            <argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
            <argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
            <argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
            <argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
            <argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument>
          </argumentList>
        </action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """
}

// MARK: - XML escaping
enum XML {
    // Escapes the five XML predefined entities. Applied to every value interpolated
    // into a document — titles come from filenames, which routinely contain "&" and
    // occasionally "<", and an unescaped one produces a malformed response that the
    // player reports only as an empty folder.
    //
    // Control characters are dropped rather than escaped, because for these there is
    // no escape that helps: XML 1.0 excludes the C0 range (bar tab, newline, and
    // carriage return) from its Char production entirely, so "&#1;" is just as
    // illegal as the raw byte. macOS permits every one of them in a filename — only
    // "/" and NUL are reserved — so a single stray control character anywhere in a
    // shared tree would make the whole DIDL-Lite document unparseable and the folder
    // containing it would come back empty on the player, with a perfectly healthy
    // "returned 12 of 12" sitting in this app's log. That is precisely the
    // looks-fine-from-the-inside failure shape this server is written to avoid, and
    // losing an unrenderable character from a title costs nothing next to it.
    //
    // Walked by Unicode scalar rather than by Character. A control character followed
    // by a combining mark forms ONE Character of two scalars, and a per-Character test
    // let that pair through whole — control byte included — which is exactly the
    // document-breaking input this exists to stop.
    static func escape(_ string: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&":  result.append(contentsOf: "&amp;".unicodeScalars)
            case "<":  result.append(contentsOf: "&lt;".unicodeScalars)
            case ">":  result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": result.append(contentsOf: "&quot;".unicodeScalars)
            case "'":  result.append(contentsOf: "&apos;".unicodeScalars)
            default:
                guard !isForbiddenInXML(scalar) else { continue }
                result.append(scalar)
            }
        }
        return String(result)
    }

    // What XML 1.0's Char production excludes and a Swift string can hold: the C0
    // controls other than tab (0x09), line feed (0x0A), and carriage return (0x0D),
    // plus the two noncharacters U+FFFE and U+FFFF.
    private static func isForbiddenInXML(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return false
        case 0x00...0x1F:      return true
        case 0xFFFE, 0xFFFF:   return true
        default:               return false
        }
    }
}
