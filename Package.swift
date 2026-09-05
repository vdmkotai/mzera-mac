// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MzeraMac",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "Mzera", targets: ["Mzera"])],
  targets: [
    .target(
      name: "CMedia", publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags(["-I/opt/homebrew/opt/ffmpeg/include", "-I/opt/homebrew/opt/webp/include"])
      ],
      linkerSettings: [
        .unsafeFlags(["-L/opt/homebrew/opt/ffmpeg/lib", "-L/opt/homebrew/opt/webp/lib"]),
        .linkedLibrary("webpdemux"), .linkedLibrary("webp"),
        .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
        .linkedLibrary("swscale"), .linkedLibrary("swresample"), .linkedLibrary("sqlite3"),
        .linkedFramework("CoreVideo"), .linkedFramework("VideoToolbox"),
      ]),
    .executableTarget(
      name: "Mzera", dependencies: ["CMedia"], resources: [.copy("Shaders.metal")],
      swiftSettings: [
        .unsafeFlags(["-strict-concurrency=complete"], .when(configuration: .debug))
      ],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("MetalKit"),
        .linkedFramework("ImageIO"), .linkedFramework("AVFoundation"),
        .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release)),
      ]),
    .testTarget(name: "MzeraTests", dependencies: ["Mzera"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
