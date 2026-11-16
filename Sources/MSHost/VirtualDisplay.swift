import CPrivateAPI
import CoreGraphics
import CryptoKit
import Foundation
import MSCodec
import MSCore
import os

public struct VirtualDisplayConfig: Equatable {
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hiDPI: Bool
    public var refreshRate: Double
    public var sizeMM: CGSize
    public var serial: UInt32
    public var colour: ColourPlan

    public init(name: String, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool,
                refreshRate: Double, sizeMM: CGSize, serial: UInt32, colour: ColourPlan = .srgb) {
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
        self.sizeMM = sizeMM
        self.serial = serial
        self.colour = colour
    }
}

public enum VirtualDisplayError: Error, Equatable {
    case privateAPIUnavailable
    case creationFailed
    case applySettingsFailed
    case invalidConfig(String)
    case mirrorFailed(Int32)
    case notMainThread
}

/// Owns a private `CGVirtualDisplay`. Main thread only.
public final class VirtualDisplay {
    private static let log = Log.logger("virtualdisplay")

    private var display: CGVirtualDisplay?
    private let maxWidth: Int
    private let maxHeight: Int
    private let cachedID: CGDirectDisplayID

    public private(set) var config: VirtualDisplayConfig
    public var onTerminated: (() -> Void)?

    public var displayID: CGDirectDisplayID { cachedID }

    private init(display: CGVirtualDisplay, config: VirtualDisplayConfig) {
        self.display = display
        self.config = config
        self.maxWidth = config.pixelWidth
        self.maxHeight = config.pixelHeight
        self.cachedID = display.displayID
    }

    deinit {
        display = nil
    }

    // MARK: Validation

    private static func validate(_ c: VirtualDisplayConfig) throws {
        guard c.pixelWidth % 2 == 0, c.pixelHeight % 2 == 0 else {
            throw VirtualDisplayError.invalidConfig("pixel size must be even")
        }
        guard (640...8192).contains(c.pixelWidth) else {
            throw VirtualDisplayError.invalidConfig("width out of range 640...8192")
        }
        guard (360...8192).contains(c.pixelHeight) else {
            throw VirtualDisplayError.invalidConfig("height out of range 360...8192")
        }
        guard c.refreshRate >= 24, c.refreshRate <= 120 else {
            throw VirtualDisplayError.invalidConfig("refresh rate out of range 24...120")
        }
        guard c.sizeMM.width > 0, c.sizeMM.height > 0 else {
            throw VirtualDisplayError.invalidConfig("physical size must be positive")
        }
    }

    private static func makeSettings(_ c: VirtualDisplayConfig) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        let w = c.hiDPI ? c.pixelWidth / 2 : c.pixelWidth
        let h = c.hiDPI ? c.pixelHeight / 2 : c.pixelHeight
        settings.hiDPI = c.hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: c.refreshRate)]
        return settings
    }

    // MARK: Lifecycle

    public static func create(_ c: VirtualDisplayConfig) throws -> VirtualDisplay {
        guard Thread.isMainThread else { throw VirtualDisplayError.notMainThread }
        try validate(c)
        guard MSPrivateAPIAvailable() else { throw VirtualDisplayError.privateAPIUnavailable }

        // The terminationHandler needs the owner; the owner needs the display. Bridge via a box.
        let box = TerminationBox()

        let desc = CGVirtualDisplayDescriptor()
        desc.name = c.name
        desc.maxPixelsWide = UInt32(c.pixelWidth)
        desc.maxPixelsHigh = UInt32(c.pixelHeight)
        desc.sizeInMillimeters = c.sizeMM
        desc.vendorID = MSConstants.vendorID
        desc.productID = MSConstants.productID
        desc.serialNum = c.serial
        desc.queue = DispatchQueue.main
        desc.redPrimary = c.colour.redPrimary
        desc.greenPrimary = c.colour.greenPrimary
        desc.bluePrimary = c.colour.bluePrimary
        desc.whitePoint = c.colour.whitePoint
        desc.terminationHandler = { _, _ in
            DispatchQueue.main.async { box.owner?.handleTerminated() }
        }

        guard let display = CGVirtualDisplay(descriptor: desc) else {
            log.error("CGVirtualDisplay init returned nil")
            throw VirtualDisplayError.creationFailed
        }
        guard display.apply(makeSettings(c)) else {
            log.error("applySettings failed in create")
            throw VirtualDisplayError.applySettingsFailed  // display released on scope exit
        }
        let vd = VirtualDisplay(display: display, config: c)
        box.owner = vd
        vd.terminationBox = box
        log.info("created virtual display id=\(vd.displayID) \(c.pixelWidth)x\(c.pixelHeight) hiDPI=\(c.hiDPI)")
        return vd
    }

    private final class TerminationBox {
        weak var owner: VirtualDisplay?
    }
    private var terminationBox: TerminationBox?

    private func handleTerminated() {
        guard display != nil else { return }
        Self.log.info("virtual display \(self.cachedID) terminated by system")
        onTerminated?()
    }

    public func apply(_ c: VirtualDisplayConfig) throws {
        guard Thread.isMainThread else { throw VirtualDisplayError.notMainThread }
        try Self.validate(c)
        guard let display else { throw VirtualDisplayError.invalidConfig("display destroyed") }
        guard c.name == config.name else { throw VirtualDisplayError.invalidConfig("name cannot change") }
        guard c.serial == config.serial else { throw VirtualDisplayError.invalidConfig("serial cannot change") }
        guard c.sizeMM == config.sizeMM else { throw VirtualDisplayError.invalidConfig("physical size cannot change") }
        guard c.pixelWidth <= maxWidth, c.pixelHeight <= maxHeight else {
            throw VirtualDisplayError.invalidConfig("pixel size exceeds the size the display was created with")
        }
        guard display.apply(Self.makeSettings(c)) else {
            Self.log.error("applySettings failed in apply")
            throw VirtualDisplayError.applySettingsFailed
        }
        config = c
    }

    public func destroy() {
        guard Thread.isMainThread else {
            Self.log.error("destroy called off the main thread")
            return
        }
        if display != nil {
            Self.log.info("destroying virtual display \(self.cachedID)")
        }
        display = nil
    }

    // MARK: Mirroring

    public func setMirrorsMain(_ on: Bool) throws {
        guard Thread.isMainThread else { throw VirtualDisplayError.notMainThread }
        guard display != nil else { throw VirtualDisplayError.invalidConfig("display destroyed") }
        let main = CGMainDisplayID()
        if on && main == cachedID {
            throw VirtualDisplayError.invalidConfig("virtual display is the main display")
        }
        var cfg: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&cfg)
        guard err == .success, let cfg else { throw VirtualDisplayError.mirrorFailed(err.rawValue) }
        err = CGConfigureDisplayMirrorOfDisplay(cfg, cachedID, on ? main : kCGNullDirectDisplay)
        if err != .success {
            CGCancelDisplayConfiguration(cfg)
            throw VirtualDisplayError.mirrorFailed(err.rawValue)
        }
        err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success {
            CGCancelDisplayConfiguration(cfg)
            throw VirtualDisplayError.mirrorFailed(err.rawValue)
        }
    }

    public var isMirroringMain: Bool {
        CGDisplayMirrorsDisplay(cachedID) == CGMainDisplayID()
    }

    // MARK: Helpers

    public static func serial(forDeviceId id: String) -> UInt32 {
        let digest = SHA256.hash(data: Data(id.utf8))
        var v: UInt32 = 0
        for b in digest.prefix(4) { v = (v << 8) | UInt32(b) }
        return v
    }

    public static func currentModeDescription(_ id: CGDirectDisplayID)
        -> (pointsWide: Int, pointsHigh: Int, pixelsWide: Int, pixelsHigh: Int, refresh: Double)? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return (m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate)
    }
}
