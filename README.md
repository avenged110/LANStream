# LAN Stream

A macOS 15 MenuBar applet that shares folders of video files with other devices on your local network as a DLNA/UPnP media server. Compatible smart TVs, media players, and similar clients can discover, browse, and play these shared files.

- Supports sharing files in Matroska and MP4/M4V/MOV container formats.
- No transcoding or remuxing support; it streams what you share exactly as it is.
- Shared folders and the server name and port can be configured in Settings.

It felt like every DLNA-style media server option out there for macOS was either garbage and/or grossly overcomplicated for what I needed and constantly giving me problems. All I want is to access Matroska files from my Mac mini file server on my Oppo UDP, so LAN Stream does exactly this and nothing more. Conforms to UPnP AV/DLNA guidelines and was tested with Oppo UDP-203/205 players and VLC.

## Installation and Usage

LAN Stream is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `LANStream.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/LAN Stream.app"
```

On first launch, you must grant LAN Stream "Local Network" permission either from Apple's TCC popup alert or in System Settings > Privacy & Security > Local Network in order for the server to be discoverable/accessed.

Please note that the server contains no authentication mechanism (expected behavior for DLNA/UPnP), so anyone on your local network can browse and play any content you share through LAN Stream.

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only.
- "Local Network" permission via Apple's TCC system.
- A local network (wired or wireless) and at least one DLNA/UPnP-capable client are needed for this to be useful.
- Sandboxed, uses Apple's Hardened Runtime, and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.
- File access is read-only.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. If it affects macOS 15, I will try harder. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it largely feature-complete at this time.

LAN Stream is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

LAN Stream is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2026 avenged110. The full license text is in `COPYING`.
