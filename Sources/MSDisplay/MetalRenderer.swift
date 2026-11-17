import Foundation
import Metal
import QuartzCore
import CoreVideo
import os
import MSCodec
import MSCore

public enum RendererError: Error {
    case noDevice
    case shaderCompilation(String)
    case pipeline(String)
    case textureCache
    case unsupportedPixelFormat(OSType)
    case textureCreation
}

public struct RendererCounters {
    public var framesSubmitted: UInt64 = 0
    public var framesDrawn: UInt64 = 0
    public var framesSkipped: UInt64 = 0
    public var drawFailures: UInt64 = 0
    public init() {}
}

/// Present-path tuning (Display). Overridable via launch arguments or
/// `defaults write app.macscreen.MacScreen msRenderVsync -bool YES` (also `msRenderDrawables`, `msRenderStreamSize`).
/// Measured on the iMac 5K (HEVC 4K60, Wi-Fi): vsync off cuts decode->present p50 from ~34 ms to ~7 ms
/// (capture->present p50 76 -> 53 ms); 3 drawables and a stream-sized drawable gave no gain.
public struct PresentOptions: Equatable {
    /// `CAMetalLayer.displaySyncEnabled`. Off by default (lowest latency; may tear). Settings "Smooth (vsync) mode"
    /// turns it on; the developer override `msRenderVsync` (if set) wins over the setting.
    public var vsync: Bool = false
    /// `CAMetalLayer.maximumDrawableCount` (2 or 3).
    public var drawables: Int = 2
    /// Size the drawable to the decoded frame (e.g. 3840x2160) and let Core Animation scale to the panel.
    public var streamSizedDrawable: Bool = false
    public init() {}

    public static func fromDefaults(_ d: UserDefaults = .standard, settingsVsync: Bool = false) -> PresentOptions {
        var o = PresentOptions()
        o.vsync = settingsVsync
        if d.object(forKey: "msRenderVsync") != nil { o.vsync = d.bool(forKey: "msRenderVsync") }
        let n = d.integer(forKey: "msRenderDrawables")
        if n == 2 || n == 3 { o.drawables = n }
        o.streamSizedDrawable = d.bool(forKey: "msRenderStreamSize")
        return o
    }
}

public final class MetalRenderer {
    private struct Frame {
        let buffer: CVPixelBuffer
        let captureMicros: UInt64
    }

    public let device: MTLDevice
    public var onPresented: ((UInt64, UInt64) -> Void)?

    private let log = Logger(subsystem: "app.macscreen", category: "display")
    private let queue = DispatchQueue(label: "ms.render", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    // Protected by `lock`:
    private var mailbox: Frame?
    private var stats = RendererCounters()
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var layer: CAMetalLayer?
    private var options = PresentOptions()

    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        self.device = dev
        guard let cq = dev.makeCommandQueue() else { throw RendererError.pipeline("command queue") }
        commandQueue = cq
        do {
            library = try dev.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RendererError.shaderCompilation(String(describing: error))
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else { throw RendererError.pipeline("sampler") }
        sampler = smp
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let c = cache else { throw RendererError.textureCache }
        textureCache = c
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        _ = try pipeline(for: .bgra8Unorm)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Layer

    public func attach(layer: CAMetalLayer, drawableSize: CGSize, tenBit: Bool = false, colour: ColourPlan = .srgb,
                       options: PresentOptions = PresentOptions()) {
        layer.device = device
        layer.pixelFormat = tenBit ? .bgr10a2Unorm : .bgra8Unorm
        layer.colorspace = CGColorSpace(name: colour.layerColourSpaceName)
        layer.displaySyncEnabled = options.vsync
        layer.maximumDrawableCount = options.drawables
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.drawableSize = drawableSize
        withLock { self.layer = layer; self.options = options }
        log.info("present options vsync=\(options.vsync) drawables=\(options.drawables) streamSized=\(options.streamSizedDrawable)")
    }

    /// Switches vsync on the attached layer (Settings "Smooth (vsync) mode"); takes effect with the next drawable.
    public func setVsync(_ on: Bool) {
        let l: CAMetalLayer? = withLock { options.vsync = on; return layer }
        l?.displaySyncEnabled = on
        log.info("present vsync=\(on)")
    }

    public var presentOptions: PresentOptions { withLock { options } }

    public func updateDrawableSize(_ size: CGSize) {
        let (l, o) = withLock { (layer, options) }
        if o.streamSizedDrawable { return }
        l?.drawableSize = size
    }

    public var counters: RendererCounters { withLock { stats } }

    public func flushTextureCache() {
        if let c = textureCache { CVMetalTextureCacheFlush(c, 0) }
    }

    // MARK: Submit / draw

    public func submit(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) {
        withLock {
            stats.framesSubmitted += 1
            if mailbox != nil { stats.framesSkipped += 1 }
            mailbox = Frame(buffer: pixelBuffer, captureMicros: captureTimeMicros)
        }
        queue.async { [weak self] in self?.drain() }
    }

    private func takeFrame() -> Frame? {
        withLock {
            guard let f = mailbox else { return nil }
            mailbox = nil
            return f
        }
    }

    private func pendingLayer() -> (CAMetalLayer?, Bool, CGSize?)? {
        withLock {
            guard let f = mailbox else { return nil }
            let size = options.streamSizedDrawable
                ? CGSize(width: CVPixelBufferGetWidth(f.buffer), height: CVPixelBufferGetHeight(f.buffer)) : nil
            return (layer, true, size)
        }
    }

    private func addFailure() { withLock { stats.drawFailures += 1 } }

    /// Runs on the render queue: draws until the mailbox is empty. The drawable is acquired *before* the
    /// frame is taken: `nextDrawable()` can block up to a vsync when all drawables are in flight, and frames
    /// decoded meanwhile replace the mailbox, so the newest frame is drawn rather than a stale one.
    private func drain() {
        while let (layer, _, streamSize) = pendingLayer() {
            guard let layer = layer else { _ = takeFrame(); addFailure(); continue }
            if let s = streamSize, layer.drawableSize != s { layer.drawableSize = s }
            guard let drawable = layer.nextDrawable() else { _ = takeFrame(); addFailure(); continue }
            guard let frame = takeFrame() else { return }
            draw(frame, drawable: drawable)
        }
    }

    private func draw(_ frame: Frame, drawable: CAMetalDrawable) {
        guard let cb = commandQueue.makeCommandBuffer() else { addFailure(); return }
        Signpost.begin("render", id: frame.captureMicros)
        let keep: [CVMetalTexture]
        do {
            keep = try encode(frame.buffer, into: cb, target: drawable.texture)
        } catch {
            log.error("draw failed: \(String(describing: error))")
            Signpost.end("render", id: frame.captureMicros)
            addFailure()
            return
        }
        cb.present(drawable)
        let capture = frame.captureMicros
        drawable.addPresentedHandler { [weak self] d in
            guard let self = self else { return }
            let now = MonoClock.nowMicros()
            var at = now
            if d.presentedTime > 0 {
                let age = max(0, CACurrentMediaTime() - d.presentedTime)
                let ageMicros = UInt64(age * 1e6)
                at = now >= ageMicros ? now - ageMicros : now
            }
            Signpost.end("render", id: capture)
            self.queue.async { self.onPresented?(capture, at) }
        }
        let buffer = frame.buffer
        cb.addCompletedHandler { _ in
            _ = keep
            _ = buffer
        }
        cb.commit()
        withLock { stats.framesDrawn += 1 }
    }

    // MARK: Offscreen

    public func renderOffscreen(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                          height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td),
              let cb = commandQueue.makeCommandBuffer() else { throw RendererError.textureCreation }
        let keep = try encode(pixelBuffer, into: cb, target: target)
        cb.commit()
        cb.waitUntilCompleted()
        _ = keep
        if let err = cb.error { throw RendererError.pipeline(String(describing: err)) }
        return target
    }

    // MARK: Internals

    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = withLock({ pipelines[format] }) { return p }
        guard let v = library.makeFunction(name: "ms_vertex"),
              let f = library.makeFunction(name: "ms_fragment") else {
            throw RendererError.pipeline("missing shader function")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        let p: MTLRenderPipelineState
        do { p = try device.makeRenderPipelineState(descriptor: d) } catch {
            throw RendererError.pipeline(String(describing: error))
        }
        withLock { pipelines[format] = p }
        return p
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
        guard let cache = textureCache else { throw RendererError.textureCache }
        var tex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, format,
            CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &tex)
        guard st == kCVReturnSuccess, let t = tex else { throw RendererError.textureCreation }
        return t
    }

    /// Encodes one render pass drawing `pb` into `target`. Returns the textures that must stay alive until completion.
    private func encode(_ pb: CVPixelBuffer, into cb: MTLCommandBuffer, target: MTLTexture) throws -> [CVMetalTexture] {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let lumaFmt: MTLPixelFormat, chromaFmt: MTLPixelFormat
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            lumaFmt = .r8Unorm; chromaFmt = .rg8Unorm
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            lumaFmt = .r16Unorm; chromaFmt = .rg16Unorm
        default:
            throw RendererError.unsupportedPixelFormat(fmt)
        }
        let pso = try pipeline(for: target.pixelFormat)
        let yTex = try planeTexture(pb, plane: 0, format: lumaFmt)
        let cTex = try planeTexture(pb, plane: 1, format: chromaFmt)
        guard let y = CVMetalTextureGetTexture(yTex), let c = CVMetalTextureGetTexture(cTex) else {
            throw RendererError.textureCreation
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { throw RendererError.pipeline("encoder") }
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(y, index: 0)
        enc.setFragmentTexture(c, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return [yTex, cTex]
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}
