// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SwiftBrowserDrop",
  platforms: [
    // Network.framework's structured-concurrency API (`NetworkListener`, `NetworkConnection`) starts here.
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(name: "BrowserDrop", targets: ["BrowserDrop"])
  ],
  targets: [
    .target(
      name: "BrowserDrop",
      resources: [
        .copy("Resources/Page")
      ]
    ),
    .testTarget(
      name: "BrowserDropTests",
      dependencies: ["BrowserDrop"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
