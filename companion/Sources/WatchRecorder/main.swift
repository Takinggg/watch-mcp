import AppKit

// WatchRecorder: menu-bar companion of watch-mcp.
//   WatchRecorder                          menu-bar app (normal use)
//   WatchRecorder --self-test <s> <out.mov> record only a test window of this app for <s> seconds
//   WatchRecorder --handoff-test <x.watch>  finalize a bundle + write latest-recording.json + print the prompt
let arguments = CommandLine.arguments
let app = NSApplication.shared

if let index = arguments.firstIndex(of: "--self-test"), arguments.count > index + 2 {
    let seconds = Double(arguments[index + 1]) ?? 3
    let output = URL(fileURLWithPath: arguments[index + 2])
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await SelfTest.recordOwnWindow(seconds: seconds, to: output)) }
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
