import Foundation
import AppKit
import CoreGraphics
import MSCodec

public struct DisplayInfo: Codable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var widthMM: Double
    public var heightMM: Double
    public var backingScale: Double
    public var edrHeadroom: Double
    public var colorSpaceName: String?
    public var refreshHz: Double

    public init(pixelWidth: Int, pixelHeight: Int, widthMM: Double, heightMM: Double, backingScale: Double,
                edrHeadroom: Double, colorSpaceName: String?, refreshHz: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.backingScale = backingScale
        self.edrHeadroom = edrHeadroom
        self.colorSpaceName = colorSpaceName
        self.refreshHz = refreshHz
    }
}

public struct CapsReport: Codable {
    public var codec: CodecCapabilities.Report
    public var display: DisplayInfo?
    public var probeVersion: Int = 1

    public init(codec: CodecCapabilities.Report, display: DisplayInfo?, probeVersion: Int = 1) {
        self.codec = codec
        self.display = display
        self.probeVersion = probeVersion
    }
}

public enum ProbeReport {
    public static func gatherCaps() -> CapsReport {
        CapsReport(codec: CodecCapabilities.report(), display: mainDisplayInfo())
    }

    public static func mainDisplayInfo() -> DisplayInfo? {
        let id = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let size = CGDisplayScreenSize(id)
        let screen = NSScreen.main
        return DisplayInfo(
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            widthMM: Double(size.width), heightMM: Double(size.height),
            backingScale: Double(screen?.backingScaleFactor ?? 1),
            edrHeadroom: Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
            colorSpaceName: screen?.colorSpace?.localizedName,
            refreshHz: mode.refreshRate)
    }
}
