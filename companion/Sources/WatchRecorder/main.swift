import AppKit

// WatchRecorder: menu-bar companion of watch-mcp.
//   WatchRecorder                          menu-bar app (normal use)
//   WatchRecorder --self-test <s> <out.mov> record only a test window of this app for <s> seconds
//   WatchRecorder --handoff-test <x.watch>  finalize a bundle + write latest-recording.json + print the prompt
//   WatchRecorder --render-ui <out> <dir> [--language en|fr|ko]
//                                           draw every screen offscreen to PNGs (recordings from <dir>)
let arguments = CommandLine.arguments
let app = NSApplication.shared

if let index = arguments.firstIndex(of: "--self-test"), arguments.count > index + 2 {
    let seconds = Double(arguments[index + 1]) ?? 3
    let output = URL(fileURLWithPath: arguments[index + 2])
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await SelfTest.recordOwnWindow(seconds: seconds, to: output)) }
    app.run()
} else if let index = arguments.firstIndex(of: "--render-ui"), arguments.count > index + 2 {
    if let lang = arguments.firstIndex(of: "--language").flatMap({ arguments.count > $0 + 1 ? AppLanguage(rawValue: arguments[$0 + 1]) : nil }) {
        L.override = lang
    }
    let out = URL(fileURLWithPath: arguments[index + 1])
    let folder = URL(fileURLWithPath: arguments[index + 2])
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await RenderUI.run(outDir: out, library: folder)) }
    app.run()
} else if let index = arguments.firstIndex(of: "--handoff-test"), arguments.count > index + 1 {
    let bundle = URL(fileURLWithPath: arguments[index + 1])
    Task { @MainActor in exit(await SelfTest.handoff(bundle: bundle)) }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
