// HDR spike (T6.2 / Gate G5). NOT part of the build.
// Creates ONE short-lived CGVirtualDisplay per run with a given mode transferFunction,
// reports how macOS sees it (EDR, colour space, depth) and what ScreenCaptureKit delivers
// from it (pixel format, colour attachments), then destroys it.
//
//   swiftc -O -o /tmp/hdr-vd-probe Scripts/spikes/hdr-vd-probe.swift
//   /tmp/hdr-vd-probe <transferFunction:int> [captureMode: none|sdr10|hdrlocal|hdrcanon]
//
// The display lives ~4-6 s and the process exits afterwards (exit also tears the display down).
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)
let tf = UInt32(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 0 : 0)
let captureMode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "none"

func cls(_ n: String) -> NSObject.Type { NSClassFromString(n) as! NSObject.Type }
func fourCC(_ v: OSType) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}

// --- create ---------------------------------------------------------------
let desc = cls("CGVirtualDisplayDescriptor").init()
desc.setValue("MS HDR Spike", forKey: "name")
desc.setValue(1920, forKey: "maxPixelsWide")
desc.setValue(1080, forKey: "maxPixelsHigh")
desc.setValue(NSValue(size: NSSize(width: 600, height: 340)), forKey: "sizeInMillimeters")
desc.setValue(0x3456, forKey: "vendorID")
desc.setValue(0xD5E7, forKey: "productID")
desc.setValue(0x5317, forKey: "serialNum")
desc.setValue(DispatchQueue.main, forKey: "queue")

typealias InitTF = @convention(c) (AnyObject, Selector, UInt, UInt, Double, UInt32) -> AnyObject
let modeCls: AnyClass = NSClassFromString("CGVirtualDisplayMode")!
let selTF = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
let imp = class_getMethodImplementation(modeCls, selTF)!
let initTF = unsafeBitCast(imp, to: InitTF.self)
let mode = initTF((modeCls as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue(),
                  selTF, 1920, 1080, 60, tf)
print("mode transferFunction readback:", (mode as! NSObject).value(forKey: "transferFunction") ?? "nil")

let settings = cls("CGVirtualDisplaySettings").init()
settings.setValue([mode], forKey: "modes")
settings.setValue(0, forKey: "hiDPI")

let vdCls: AnyClass = NSClassFromString("CGVirtualDisplay")!
typealias InitD = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
let selInit = NSSelectorFromString("initWithDescriptor:")
let initD = unsafeBitCast(class_getMethodImplementation(vdCls, selInit)!, to: InitD.self)
var vd: NSObject? = initD((vdCls as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue(),
                          selInit, desc) as? NSObject
guard let display = vd else { print("RESULT tf=\(tf) create=FAIL"); exit(1) }
typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
let selApply = NSSelectorFromString("applySettings:")
let ok = unsafeBitCast(class_getMethodImplementation(vdCls, selApply)!, to: Apply.self)(display, selApply, settings)
let did = (display.value(forKey: "displayID") as! NSNumber).uint32Value
print("created displayID=\(did) applySettings=\(ok)")

func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
spin(2.5)

// --- inspect --------------------------------------------------------------
_ = NSApplication.shared
var edrPot: CGFloat = -1, edrCur: CGFloat = -1, edrRef: CGFloat = -1
var depth = -1, csName = "?"
if let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == did }) {
    edrPot = s.maximumPotentialExtendedDynamicRangeColorComponentValue
    edrCur = s.maximumExtendedDynamicRangeColorComponentValue
    edrRef = s.maximumReferenceExtendedDynamicRangeColorComponentValue
    depth = s.depth.bitsPerPixel
    csName = s.colorSpace?.localizedName ?? "nil"
} else { print("NSScreen not found for \(did)") }
let cgcs = CGDisplayCopyColorSpace(did)
let cgName = (cgcs.name as String?) ?? "unnamed"
let isHDRcs = CGColorSpaceUsesITUR_2100TF(cgcs) || cgcs.isHDR()
var modeDepth = "?"
if let m = CGDisplayCopyDisplayMode(did) {
    modeDepth = "\(m.pixelWidth)x\(m.pixelHeight)@\(m.refreshRate) ioflags=0x\(String(m.ioFlags, radix: 16))"
}
print("NSScreen edrPotential=\(edrPot) edrCurrent=\(edrCur) edrReference=\(edrRef) bpp=\(depth) cs=\(csName)")
print("CG colourSpace=\(cgName) hdrCS=\(isHDRcs) mode=\(modeDepth)")

// --- capture --------------------------------------------------------------
final class Out: NSObject, SCStreamOutput {
    var done = false
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of t: SCStreamOutputType) {
        guard t == .screen, !done, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        done = true
        let pf = CVPixelBufferGetPixelFormatType(pb)
        let att = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
        let keys = [kCVImageBufferTransferFunctionKey, kCVImageBufferColorPrimariesKey, kCVImageBufferYCbCrMatrixKey].map { $0 as String }
        let summary = keys.map { "\($0.replacingOccurrences(of: "CVImageBuffer", with: ""))=\(att[$0] ?? "nil")" }.joined(separator: " ")
        var csInfo = "nil"
        if let cs = CVImageBufferCreateColorSpaceFromAttachments(att as CFDictionary)?.takeRetainedValue() {
            csInfo = "\(cs.name.map { $0 as String } ?? "unnamed") hdr=\(CGColorSpaceUsesITUR_2100TF(cs))"
        }
        print("CAPTURE pf=\(fourCC(pf)) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) \(summary) cs=\(csInfo)")
        // Luma code range of a 10-bit bi-planar buffer (16-bit containers, MSB-aligned).
        if CVPixelBufferIsPlanar(pb), [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(pf) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            var lo = UInt16.max, hi = UInt16.min
            for y in stride(from: 0, to: CVPixelBufferGetHeightOfPlane(pb, 0), by: 4) {
                let row = UnsafeRawPointer(base + y * bpr).assumingMemoryBound(to: UInt16.self)
                for x in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(pb, 0), by: 4) { let v = row[x] >> 6; lo = min(lo, v); hi = max(hi, v) }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            print("CAPTURE luma10 min=\(lo) max=\(hi)")
        }
    }
}
if captureMode != "none" {
    let out = Out()
    var stream: SCStream?
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let d = content.displays.first(where: { $0.displayID == did }) else { print("CAPTURE no SCDisplay"); return }
            let cfg: SCStreamConfiguration
            switch captureMode {
            case "hdrlocal": cfg = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            case "hdrcanon": cfg = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            case "hdrlocal420": // encoder-ready: HDR range, 4:2:0 10-bit video range
                cfg = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case "sdr420": // 10-bit SDR, encoder-ready
                cfg = SCStreamConfiguration(); cfg.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            default: cfg = SCStreamConfiguration(); cfg.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            }
            cfg.width = 1920; cfg.height = 1080
            print("CAPTURE cfg mode=\(captureMode) pf=\(fourCC(cfg.pixelFormat)) range=\(cfg.captureDynamicRange.rawValue) cs=\(cfg.colorSpaceName as String)")
            let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
            try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: .main)
            try await s.startCapture()
            stream = s
        } catch { print("CAPTURE error: \(error)") }
    }
    let deadline = Date().addingTimeInterval(4)
    while !out.done && Date() < deadline { spin(0.1) }
    if !out.done { print("CAPTURE no frame within 4 s") }
    if let s = stream { Task { try? await s.stopCapture() }; spin(0.3) }
}

// --- destroy --------------------------------------------------------------
vd = nil
spin(0.5)
print("RESULT tf=\(tf) cap=\(captureMode) edrPotential=\(edrPot) cs=\(cgName) destroyed")
exit(0)
