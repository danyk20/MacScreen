import AppKit
import MSCodec
import MSProtocol

enum LocalCapabilities {
    static func make(role: Role, windowed: Bool, deviceName: String) -> CapabilitiesMessage {
        var w = 1920, h = 1080, scale = 2.0
        var mm = CGSize(width: 600, height: 340)
        if !windowed || role == .host, let screen = NSScreen.main {
            scale = Double(screen.backingScaleFactor)
            w = Int(screen.frame.width * screen.backingScaleFactor)
            h = Int(screen.frame.height * screen.backingScaleFactor)
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let s = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
                if s.width > 0, s.height > 0 { mm = s }
            }
        }
        var wide = false
        if !windowed || role == .host, let cs = NSScreen.main?.colorSpace?.cgColorSpace {
            wide = cs.name == CGColorSpace.displayP3 || (cs.isWideGamutRGB && cs.name != CGColorSpace.sRGB)
        }
        let hevcDec = CodecCapabilities.hardwareDecodeSupported(.hevc)
        let h264Dec = CodecCapabilities.hardwareDecodeSupported(.h264)
        return CapabilitiesMessage(
            role: role.rawValue, deviceName: deviceName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            panelPixelWidth: w, panelPixelHeight: h, panelWidthMM: Double(mm.width), panelHeightMM: Double(mm.height),
            backingScale: scale, edrHeadroom: 1, refreshHz: 60,
            hwDecodeH264: h264Dec, hwDecodeHEVC: hevcDec, hwEncodeH264: true, hwEncodeHEVC: true,
            wideColor: wide)
    }
}
