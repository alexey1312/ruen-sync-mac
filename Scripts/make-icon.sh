#!/usr/bin/env bash
# =============================================================================
# make-icon.sh — generate AppIcon.appiconset from a Swift Core Graphics script.
# =============================================================================
# Renders a 1024×1024 PNG with "EN" (blue) / "RU" (red) on a dark background,
# then uses `sips` to downsize into all sizes Xcode expects, and writes a
# Contents.json so Tuist+Xcode pick it up via Assets.xcassets.
#
# Run:
#   bash Scripts/make-icon.sh
#
# Re-run is idempotent — fully overwrites the appiconset.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${ROOT}/RuEnSync/Resources/Assets.xcassets"
APPICON="${ASSETS}/AppIcon.appiconset"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${APPICON}"

MASTER="${TMP_DIR}/master_1024.png"
SRC="${TMP_DIR}/render.swift"

# --- 1. Render the master 1024×1024 PNG via Swift + CoreGraphics ------------
# Use a temp .swift file + swiftc with explicit AppKit linkage. `swift -`
# (script mode) cannot resolve AppKit symbols at JIT time on macOS.
cat > "${SRC}" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

guard let context = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to allocate CGContext\n", stderr); exit(1)
}

// Background — rounded rect, deep indigo. macOS Big Sur+ uses squircle masks
// for app icons; we just draw a filled rounded rect because Xcode masks it
// for us automatically when it pulls 1024×1024.
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
context.addPath(bgPath)
context.setFillColor(NSColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor)
context.fillPath()

// Diagonal divider (subtle)
context.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor)
context.setLineWidth(6)
context.move(to: CGPoint(x: size * 0.12, y: size * 0.88))
context.addLine(to: CGPoint(x: size * 0.88, y: size * 0.12))
context.strokePath()

// Text rendering: "EN" upper-left, "RU" lower-right
let blue = NSColor(red: 0.32, green: 0.62, blue: 1.0, alpha: 1)
let red = NSColor(red: 1.0, green: 0.35, blue: 0.42, alpha: 1)
let font = NSFont.systemFont(ofSize: size * 0.32, weight: .heavy)

func draw(_ text: String, at point: CGPoint, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let attr = NSAttributedString(string: text, attributes: attrs)
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    attr.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

draw("EN", at: CGPoint(x: size * 0.16, y: size * 0.58), color: blue)
draw("RU", at: CGPoint(x: size * 0.40, y: size * 0.14), color: red)

guard let image = context.makeImage() else {
    fputs("makeImage failed\n", stderr); exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("PNG encode failed\n", stderr); exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(data.count) bytes)")
SWIFT

BIN="${TMP_DIR}/render"
swiftc "${SRC}" -framework AppKit -o "${BIN}"
"${BIN}" "${MASTER}"

if [[ ! -f "${MASTER}" ]]; then
  echo "❌ Master PNG not created" >&2
  exit 1
fi
echo "→ master 1024×1024 rendered"

# --- 2. Downscale into all sizes required by macOS AppIcon ------------------
declare -a SIZES=(16 32 64 128 256 512 1024)
for sz in "${SIZES[@]}"; do
  out="${APPICON}/icon_${sz}.png"
  sips -s format png -z "${sz}" "${sz}" "${MASTER}" --out "${out}" >/dev/null
done
echo "→ scaled all sizes"

# --- 3. Generate Contents.json --------------------------------------------
cat > "${APPICON}/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",    "filename" : "icon_16.png"   },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",    "filename" : "icon_32.png"   },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",    "filename" : "icon_32.png"   },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",    "filename" : "icon_64.png"   },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128",  "filename" : "icon_128.png"  },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128",  "filename" : "icon_256.png"  },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256",  "filename" : "icon_256.png"  },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256",  "filename" : "icon_512.png"  },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512",  "filename" : "icon_512.png"  },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512",  "filename" : "icon_1024.png" }
  ],
  "info" : { "version" : 1, "author" : "make-icon.sh" }
}
JSON

# --- 4. Top-level Assets.xcassets manifest --------------------------------
if [[ ! -f "${ASSETS}/Contents.json" ]]; then
  cat > "${ASSETS}/Contents.json" <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
fi

echo ""
echo "✔ AppIcon written to ${APPICON}"
ls -1 "${APPICON}"
