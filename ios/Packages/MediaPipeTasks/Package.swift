// swift-tools-version: 5.8
//
// A thin local wrapper around Google's prebuilt MediaPipe Tasks Vision
// frameworks (Apache-2.0). It pins the exact xcframework zips (URL and
// checksum, copied from google-ai-edge/mediapipe's own Package.swift) so
// the build downloads about 100 MB of binaries instead of cloning the
// whole MediaPipe repository. To update, copy the three url/checksum pairs
// from https://github.com/google-ai-edge/mediapipe/blob/master/Package.swift
import PackageDescription

let package = Package(
    name: "MediaPipeTasks",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "MediaPipeTasksVision",
            targets: ["MediaPipeTasksVision", "MediaPipeTasksCommon"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "MediaPipeTasksCommonBinary",
            url: "https://dl.google.com/cpdc/20261013-213039/MediaPipeTasksCommon-1.1.1.xcframework.zip",
            checksum: "25690f3005c0405a7f27b6d273b4db241811d00fbb01c54004057ee1d0e983d8"
        ),
        .binaryTarget(
            name: "MediaPipeTaskGraphsBinary",
            url: "https://dl.google.com/cpdc/20261013-213039/MediaPipeTaskGraphs-1.1.1.xcframework.zip",
            checksum: "e4d88ed65c101764ef90281a411b9942f369e48673d448eff1f934e1f68d9633"
        ),
        .binaryTarget(
            name: "MediaPipeTasksVision",
            url: "https://dl.google.com/cpdc/20261013-213039/MediaPipeTasksVision-1.1.1.xcframework.zip",
            checksum: "755390ce853b062536899f0729321156d4cdceb263aa92c4bf3b2dd05fe640e0"
        ),
        .target(
            name: "MediaPipeTasksCommon",
            dependencies: [
                "MediaPipeTasksCommonBinary",
                "MediaPipeTaskGraphsBinary",
                "MediaPipeTasksVision",
            ],
            linkerSettings: [
                // -all_load keeps the C++ calculator registrations that the
                // Apple linker would otherwise strip (same as upstream).
                .unsafeFlags(["-Xlinker", "-all_load"]),
                .linkedLibrary("c++"),
                // The common binary contains a sqlite-backed vector store.
                .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
