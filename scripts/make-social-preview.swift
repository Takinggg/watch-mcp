// Draws docs/social-preview.png (1280x640), the picture GitHub shows when the repository link is
// shared. Upload it in the repository's Settings > General > Social preview.
// Usage: swift scripts/make-social-preview.swift "$PWD"
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let accent = Color(red: 0.31, green: 0.27, blue: 0.90)
let ink = Color(red: 0.12, green: 0.11, blue: 0.13)

func image(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else {
        FileHandle.standardError.write(Data("missing \(path)\n".utf8))
        exit(1)
    }
    return image
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 19, weight: .semibold)).foregroundStyle(accent)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1.5))
    }
}

struct Preview: View {
    let logo: NSImage
    let shot: NSImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.969, green: 0.961, blue: 0.949)
            Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit).frame(width: 700)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                .offset(x: 640, y: 150)
            VStack(alignment: .leading, spacing: 22) {
                Image(nsImage: logo).resizable().frame(width: 92, height: 92)
                Text("watch-mcp").font(.system(size: 78, weight: .bold, design: .serif)).foregroundStyle(ink)
                Text("Let Claude, Codex and Cursor \(Text("watch your screen recordings.").foregroundStyle(accent))").foregroundStyle(ink)
                    .font(.system(size: 36, weight: .semibold, design: .serif))
                    .frame(width: 540, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Chip(text: "MCP server")
                    Chip(text: "Local Whisper")
                    Chip(text: "macOS app")
                }
            }
            .padding(.leading, 72).padding(.top, 70)
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Preview(logo: image("docs/logo.png"), shot: image("docs/screenshots/recording.png")))
    renderer.scale = 1
    guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not render\n".utf8))
        exit(1)
    }
    let out = root.appendingPathComponent("docs/social-preview.png")
    do {
        try png.write(to: out)
        print("wrote \(out.path) (\(cg.width)x\(cg.height))")
    } catch {
        FileHandle.standardError.write(Data("could not write: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
