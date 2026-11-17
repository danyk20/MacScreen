// HDR spike (T6.2): dump the ObjC runtime surface of the private CGVirtualDisplay* classes.
// Run: swift Scripts/spikes/dump-cgvd-runtime.swift   (creates no display)
import Foundation
import CoreGraphics
import ObjectiveC

func dump(_ name: String) {
    guard let cls: AnyClass = NSClassFromString(name) else { print("== \(name): MISSING"); return }
    print("== \(name) (super: \(class_getSuperclass(cls).map { NSStringFromClass($0) } ?? "-"))")
    var n: UInt32 = 0
    if let props = class_copyPropertyList(cls, &n) {
        for i in 0..<Int(n) {
            let p = props[i]
            let attrs = property_getAttributes(p).map { String(cString: $0) } ?? ""
            print("  prop \(String(cString: property_getName(p)))  [\(attrs)]")
        }
        free(props)
    }
    for (label, c): (String, AnyClass) in [("-", cls), ("+", object_getClass(cls)!)] {
        var m: UInt32 = 0
        if let ms = class_copyMethodList(c, &m) {
            let names = (0..<Int(m)).map { NSStringFromSelector(method_getName(ms[$0])) }.sorted()
            for s in names { print("  \(label)\(s)") }
            free(ms)
        }
    }
    var iv: UInt32 = 0
    if let ivs = class_copyIvarList(cls, &iv) {
        for i in 0..<Int(iv) {
            let v = ivs[i]
            print("  ivar \(ivar_getName(v).map { String(cString: $0) } ?? "?") \(ivar_getTypeEncoding(v).map { String(cString: $0) } ?? "")")
        }
        free(ivs)
    }
}
_ = CGMainDisplayID() // make sure CoreGraphics is loaded
dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let names = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst())
    : ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode",
       "SLVirtualDisplay", "SLVirtualDisplayConfiguration", "SLVirtualDisplaySettings", "SLVirtualDisplayMode"]
for n in names { dump(n) }
