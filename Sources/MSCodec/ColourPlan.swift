import CoreGraphics
import CoreMedia
import Foundation

/// Colour decisions for the whole pipeline, derived only from whether the Display panel is wide-colour (P3).
/// Pure value type; no wire-format change (the Display's `CapabilitiesMessage.wideColor` is the input).
public struct ColourPlan: Equatable {
    public var panelIsP3: Bool

    public init(panelIsP3: Bool) { self.panelIsP3 = panelIsP3 }

    public static let srgb = ColourPlan(panelIsP3: false)
    public static let displayP3 = ColourPlan(panelIsP3: true)

    // Virtual display primaries (CGVirtualDisplayDescriptor).
    public var redPrimary: CGPoint { panelIsP3 ? CGPoint(x: 0.680, y: 0.320) : CGPoint(x: 0.64, y: 0.33) }
    public var greenPrimary: CGPoint { panelIsP3 ? CGPoint(x: 0.265, y: 0.690) : CGPoint(x: 0.30, y: 0.60) }
    public var bluePrimary: CGPoint { panelIsP3 ? CGPoint(x: 0.150, y: 0.060) : CGPoint(x: 0.15, y: 0.06) }
    public var whitePoint: CGPoint { CGPoint(x: 0.3127, y: 0.3290) }

    /// SCStreamConfiguration.colorSpaceName
    public var captureColourSpaceName: CFString { panelIsP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB }
    /// CAMetalLayer.colorspace
    public var layerColourSpaceName: CFString { panelIsP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB }

    // Encoder VUI. Display P3 = P3 primaries with the sRGB transfer curve; matrix stays BT.709.
    public var vuiPrimaries: CFString {
        panelIsP3 ? kCMFormatDescriptionColorPrimaries_P3_D65 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2
    }
    public var vuiTransfer: CFString {
        panelIsP3 ? kCMFormatDescriptionTransferFunction_sRGB : kCMFormatDescriptionTransferFunction_ITU_R_709_2
    }
    public var vuiMatrix: CFString { kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 }
}
