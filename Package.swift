// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Dakodeon",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Dakodeon", targets: ["Dakodeon"])
  ],
  targets: [
    .executableTarget(name: "Dakodeon")
  ]
)
