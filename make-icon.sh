#!/bin/bash
# Generate AppIcon.icns for Grove from scratch (no design tools needed).
# Renders a 1024px master with CoreGraphics, then builds the .iconset + .icns.
# Re-run anytime you want to tweak the icon; output is AppIcon.icns.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
MASTER="$WORK/icon_1024.png"
ICONSET="$WORK/Grove.iconset"
SWIFT="$WORK/gen.swift"

trap 'rm -rf "$WORK"' EXIT

cat > "$SWIFT" <<'SWIFTEOF'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
let f = CGFloat(S)

// Rounded-rect ("squircle-ish") background with a green vertical gradient.
let margin: CGFloat = 96
let rect = CGRect(x: margin, y: margin, width: f - 2*margin, height: f - 2*margin)
let radius: CGFloat = 190
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.22, green: 0.66, blue: 0.42, alpha: 1),
    CGColor(red: 0.10, green: 0.40, blue: 0.26, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: f), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Node-graph glyph: a root node branching to three children (a little "grove").
struct Node { let c: CGPoint; let r: CGFloat }
let root = Node(c: CGPoint(x: 360, y: 512), r: 78)
let kids = [
    Node(c: CGPoint(x: 700, y: 700), r: 52),
    Node(c: CGPoint(x: 720, y: 512), r: 52),
    Node(c: CGPoint(x: 700, y: 324), r: 52),
]

// Connectors (behind the nodes): smooth curves from root to each child.
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
for k in kids {
    let start = CGPoint(x: root.c.x + root.r, y: root.c.y)
    let end = CGPoint(x: k.c.x - k.r, y: k.c.y)
    let dx = (end.x - start.x) * 0.5
    ctx.move(to: start)
    ctx.addCurve(to: end,
                 control1: CGPoint(x: start.x + dx, y: start.y),
                 control2: CGPoint(x: end.x - dx, y: end.y))
    ctx.strokePath()
}

// Nodes: solid white discs with a soft green core dot.
func disc(_ n: Node) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: n.c.x - n.r, y: n.c.y - n.r, width: 2*n.r, height: 2*n.r))
    let ir = n.r * 0.42
    ctx.setFillColor(CGColor(red: 0.13, green: 0.46, blue: 0.30, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: n.c.x - ir, y: n.c.y - ir, width: 2*ir, height: 2*ir))
}
disc(root)
kids.forEach(disc)

guard let img = ctx.makeImage() else { fatalError("no image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
SWIFTEOF

echo "→ rendering 1024px master"
swift "$SWIFT" "$MASTER"

echo "→ building iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$MASTER" --out "$ICONSET/icon_$2.png" >/dev/null
done

echo "→ packing AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$HERE/AppIcon.icns"
echo "✅ Wrote $HERE/AppIcon.icns"
