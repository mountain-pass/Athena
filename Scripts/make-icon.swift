#!/usr/bin/env swift
//
//  Generates Athena's app icon + in-app logo from a source image.
//
//  Usage:
//      swift Scripts/make-icon.swift path/to/coin.png
//
//  What it does:
//    • keys out the blue/dark backdrop → transparent
//    • crops to the coin and applies an anti-aliased circular mask
//    • writes Athena/Resources/Assets.xcassets/AppIcon.appiconset (all sizes)
//    • writes Athena/Resources/Assets.xcassets/AthenaLogo.imageset (1x/2x/3x)
//
//  No dependencies beyond Xcode's toolchain.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Args

let args = CommandLine.arguments
guard args.count > 1 else {
    print("""
    usage: swift Scripts/make-icon.swift <source-image>

    Example:
      swift Scripts/make-icon.swift ~/Desktop/athena-coin.png
    """)
    exit(1)
}
let sourcePath = (args[1] as NSString).expandingTildeInPath
guard let sourceImage = NSImage(contentsOfFile: sourcePath),
      let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("✗ Could not read image at \(sourcePath)")
    exit(1)
}

let projectRoot = FileManager.default.currentDirectoryPath
let assetsDir = "\(projectRoot)/Athena/Resources/Assets.xcassets"
let appIconDir = "\(assetsDir)/AppIcon.appiconset"
let logoDir = "\(assetsDir)/AthenaLogo.imageset"

// MARK: - Load pixels

let width = sourceCG.width
let height = sourceCG.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)

guard let ctx = CGContext(data: &pixels, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("✗ Could not create bitmap context"); exit(1)
}
ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - Background removal
//
// The backdrop is blue velvet; the coin is silver/gold (r ≈ g ≥ b).
// A pixel is background when blue clearly dominates red and green.

func isBackdrop(r: UInt8, g: UInt8, b: UInt8) -> Bool {
    let rf = Double(r), gf = Double(g), bf = Double(b)
    let blueDominant = bf > rf * 1.12 && bf > gf * 1.08
    let dark = (rf + gf + bf) / 3 < 140
    return blueDominant && dark
}

for i in stride(from: 0, to: pixels.count, by: 4) {
    if isBackdrop(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]) {
        pixels[i + 3] = 0
    }
}

// MARK: - Find the coin's bounds (opaque pixel extents)

var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let a = pixels[(y * width + x) * 4 + 3]
        if a > 40 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
if minX >= maxX || minY >= maxY {   // nothing keyed out — use the whole frame
    minX = 0; minY = 0; maxX = width - 1; maxY = height - 1
}

let cropW = maxX - minX + 1
let cropH = maxY - minY + 1
let side = max(cropW, cropH)
let cropRect = CGRect(
    x: CGFloat(minX) - CGFloat(side - cropW) / 2,
    y: CGFloat(minY) - CGFloat(side - cropH) / 2,
    width: CGFloat(side), height: CGFloat(side))

guard let keyedCG = ctx.makeImage() else { print("✗ bitmap failed"); exit(1) }

// MARK: - Render at a given size with a circular mask

func render(size: Int, inset: CGFloat = 0.005) -> CGImage? {
    guard let out = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    out.interpolationQuality = .high
    out.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Anti-aliased circular clip keeps stray backdrop out of the corners.
    let d = CGFloat(size)
    let circle = CGRect(x: d * inset, y: d * inset,
                        width: d * (1 - inset * 2), height: d * (1 - inset * 2))
    out.addEllipse(in: circle)
    out.clip()

    // Draw the cropped coin square into the full canvas.
    if let cropped = keyedCG.cropping(to: cropRect) {
        out.draw(cropped, in: CGRect(x: 0, y: 0, width: d, height: d))
    } else {
        out.draw(keyedCG, in: CGRect(x: 0, y: 0, width: d, height: d))
    }
    return out.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { print("✗ could not write \(path)"); return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Emit assets

let fm = FileManager.default
try? fm.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: logoDir, withIntermediateDirectories: true)

// macOS icon matrix: (pt size, scale)
let iconSpecs: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

var iconEntries: [String] = []
for spec in iconSpecs {
    let px = spec.pt * spec.scale
    let name = "icon_\(spec.pt)x\(spec.pt)\(spec.scale == 2 ? "@2x" : "").png"
    if let img = render(size: px) {
        write(img, to: "\(appIconDir)/\(name)")
        print("  ✓ \(name) (\(px)px)")
    }
    iconEntries.append("""
        {
          "size" : "\(spec.pt)x\(spec.pt)",
          "idiom" : "mac",
          "filename" : "\(name)",
          "scale" : "\(spec.scale)x"
        }
    """)
}

let iconJSON = """
{
  "images" : [
\(iconEntries.joined(separator: ",\n"))
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
"""
try? iconJSON.write(toFile: "\(appIconDir)/Contents.json", atomically: true, encoding: .utf8)

// In-app logo (transparent, used by AthenaMark)
for (suffix, px) in [("", 256), ("@2x", 512), ("@3x", 768)] {
    if let img = render(size: px) {
        write(img, to: "\(logoDir)/AthenaLogo\(suffix).png")
    }
}
let logoJSON = """
{
  "images" : [
    { "idiom" : "universal", "filename" : "AthenaLogo.png", "scale" : "1x" },
    { "idiom" : "universal", "filename" : "AthenaLogo@2x.png", "scale" : "2x" },
    { "idiom" : "universal", "filename" : "AthenaLogo@3x.png", "scale" : "3x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
"""
try? logoJSON.write(toFile: "\(logoDir)/Contents.json", atomically: true, encoding: .utf8)

// Root Contents.json for the catalog
let rootJSON = """
{
  "info" : { "version" : 1, "author" : "xcode" }
}
"""
try? rootJSON.write(toFile: "\(assetsDir)/Contents.json", atomically: true, encoding: .utf8)

print("""

✓ Done.
  App icon → \(appIconDir)
  Logo     → \(logoDir)

Next:  xcodegen && open Athena.xcodeproj    (⌘R)

If the backdrop wasn't fully removed, tweak isBackdrop() thresholds in this
script — or pre-cut the image and pass a PNG that already has transparency.
""")
