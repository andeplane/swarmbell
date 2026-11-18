import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Deterministic platform exports of the selected artwork. This keeps the ImageGen
// original intact; iOS/watchOS apply their own mask and macOS needs an inset tile.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/ForestChime.png")
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
  let artwork = CGImageSourceCreateImageAtIndex(input, 0, nil)
else { fatalError("Could not load the selected Forest Chime artwork") }

func export(to url: URL, inset: CGFloat = 0, radius: CGFloat = 0) throws {
  let size = 1024
  guard
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: (inset > 0 ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast)
        .rawValue)
  else { fatalError("Could not create icon context") }
  let rect = CGRect(
    x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
  if radius > 0 {
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
  }
  context.interpolationQuality = .high
  context.draw(artwork, in: rect)
  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("Could not export platform icon") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not finish platform icon")
  }
}

try export(to: root.appendingPathComponent("Resources/Swarmbell.png"), inset: 80, radius: 196)
for target in ["ios", "watch"] {
  try export(
    to: root.appendingPathComponent("apps/\(target)/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
  )
}
let iconset = root.appendingPathComponent("work/ForestChime.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func run(_ executable: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { fatalError("Icon export failed: \(executable)") }
}
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try run(
      "/usr/bin/sips",
      [
        "-z", String(pixels), String(pixels),
        root.appendingPathComponent("Resources/Swarmbell.png").path, "--out",
        iconset.appendingPathComponent(name).path,
      ])
  }
}
try run(
  "/usr/bin/iconutil",
  ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/Swarmbell.icns").path])
print("Exported Forest Chime PNGs and macOS icon resource")
