// swift-tools-version: 6.0
import Foundation
import PackageDescription

let bridge = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("BridgeC/include/IysCodeMovilCore.h").path
let package = Package(
    name: "IysCodeMovil",
    platforms: [.iOS("16.4")],
    products: [.library(name: "IysCodeMovil", targets: ["IysCodeMovil"])],
    targets: [
        .binaryTarget(name: "llama", path: "llama.xcframework"),
        .target(name: "GUSBridgeC", dependencies: ["llama"], path: "BridgeC",
                publicHeadersPath: "include"),
        .target(name: "IysCodeMovilCore", dependencies: ["GUSBridgeC", "llama"],
                path: "CoreSources", exclude: [
                    "Model/GUSLlamaBridge.c", "Model/GUSLlamaBridge.h",
                    "Model/GUSPythonBridge.c", "Model/GUSPythonBridge.h",
                    "Model/pocketpy.c", "Model/pocketpy.h", "Model/IysCodeMovilCore.h",
                    "Diagnostics/GUSSignalTrap.c", "Diagnostics/GUSSignalTrap.h"
                ], swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-import-objc-header", bridge])]),
        .target(name: "IysCodeMovil", dependencies: ["IysCodeMovilCore"], path: "AppSources",
                exclude: ["LaunchScreen.storyboard"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
