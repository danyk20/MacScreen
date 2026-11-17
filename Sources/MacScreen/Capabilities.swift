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
        // Test hook: a windowed (loopback) Display advertises this panel, e.g. `-msWindowedPanel 5120x2880`;
        // `-msWindowedP3 YES` advertises a wide-colour panel.
        if windowed && role == .display, let o = UserDefaults.standard.string(forKey: "msWindowedPanel") {
            let p = o.split(separator: "x").compactMap { Int($0) }
            if p.count == 2, p[0] > 0, p[1] > 0 { w = p[0]; h = p[1] }
        }
        var wide = false
        if !windowed || role == .host, let cs = NSScreen.main?.colorSpace?.cgColorSpace {
            wide = cs.name == CGColorSpace.displayP3 || (cs.isWideGamutRGB && cs.name != CGColorSpace.sRGB)
        }
        if windowed && role == .display && UserDefaults.standard.bool(forKey: "msWindowedP3") { wide = true }
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
