// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacScreen",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "msprobe", targets: ["MSProbeCLI"]),
        .executable(name: "MacScreen", targets: ["MacScreen"]),
    ],
    targets: [
        .target(name: "CPrivateAPI", path: "Sources/CPrivateAPI"),
        .target(name: "CMSAtomics", path: "Sources/CMSAtomics"),
        .target(name: "MSCore", dependencies: ["CMSAtomics"]),
        .target(name: "MSProtocol", dependencies: ["MSCore"]),
        .target(name: "MSTransport", dependencies: ["MSCore", "MSProtocol"]),
        .target(name: "MSCodec", dependencies: ["MSCore"]),
        .target(name: "MSProbe", dependencies: ["MSCore", "MSProtocol", "MSTransport", "MSCodec"]),
        .target(name: "MSHost", dependencies: ["CPrivateAPI", "MSCore", "MSProtocol", "MSTransport", "MSCodec", "MSProbe"]),
        .target(name: "MSDisplay", dependencies: ["MSCore", "MSProtocol", "MSTransport", "MSCodec", "MSProbe"]),
        .executableTarget(name: "MSProbeCLI", dependencies: ["MSCore", "MSCodec", "MSProbe"]),
        .executableTarget(name: "MacScreen", dependencies: [
            "MSCore", "MSProtocol", "MSTransport", "MSCodec", "MSProbe", "MSHost", "MSDisplay",
        ]),
        .testTarget(name: "MSCoreTests", dependencies: ["MSCore"]),
        .testTarget(name: "MSProtocolTests", dependencies: ["MSProtocol"]),
        .testTarget(name: "MSTransportTests", dependencies: ["MSTransport"]),
        .testTarget(name: "MSCodecTests", dependencies: ["MSCodec"]),
        .testTarget(name: "MSProbeTests", dependencies: ["MSProbe"]),
        .testTarget(name: "MSHostTests", dependencies: ["MSHost", "MSProbe"]),
        .testTarget(name: "MSIntegrationTests", dependencies: [
            "MSCore", "MSProtocol", "MSTransport", "MSCodec", "MSProbe", "MSHost", "MSDisplay",
        ]),
        .testTarget(name: "MacScreenTests", dependencies: ["MacScreen"]),
        .testTarget(name: "MSDisplayTests", dependencies: ["MSDisplay", "MSProbe"]),
    ]
)
