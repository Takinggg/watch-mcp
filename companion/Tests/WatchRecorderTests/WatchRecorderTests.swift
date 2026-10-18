import AppKit
import AVFoundation
import Carbon
import Foundation
import Testing
@testable import WatchRecorder

@Suite struct HotKeySpecTests {
    @Test func parsesModifiersAndKey() throws {
        let spec = try #require(HotKeySpec.parse("ctrl+opt+r"))
        #expect(spec.keyCode == UInt32(kVK_ANSI_R))
        #expect(spec.modifiers == UInt32(controlKey | optionKey))
        #expect(spec.display == "⌃⌥R")
    }

    @Test func rejectsShortcutsWithoutModifierOrUnknownParts() {
        #expect(HotKeySpec.parse("r") == nil)
        #expect(HotKeySpec.parse("hyper+r") == nil)
        #expect(HotKeySpec.parse("cmd+f13") == nil)
        #expect(HotKeySpec.parse("") == nil)
    }

    @Test func defaultIsOptionShiftR() {
        #expect(HotKeySpec.default.display == "⌥⇧R")
        #expect(HotKeySpec.default.modifiers == UInt32(optionKey | shiftKey))
    }
}

@Suite struct HandoffTests {
    @Test func promptQuotesSpeechAndPointsToTheTools() {
        let bundle = URL(fileURLWithPath: "/tmp/Recording.watch")
        let prompt = Handoff.prompt(recording: bundle, duration: 83.4, transcript: "fix the export dialog")
        #expect(prompt.contains("Recording: /tmp/Recording.watch (1:23)"))
        #expect(prompt.contains("What I said: \"fix the export dialog\""))
        #expect(prompt.contains("latest_recording"))
    }

    @Test func promptSaysWhenThereIsNoSpeech() {
        let bundle = URL(fileURLWithPath: "/tmp/a.watch")
        #expect(Handoff.prompt(recording: bundle, duration: 5, transcript: "").contains("(no speech detected)"))
        #expect(Handoff.prompt(recording: bundle, duration: 5, transcript: nil).contains("(not transcribed)"))
    }

    @Test func latestRecordingFileMatchesTheServerFormat() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wr-\(UUID().uuidString)")
        setenv("WATCH_MCP_STATE_DIR", folder.path, 1)
        defer { unsetenv("WATCH_MCP_STATE_DIR") }
        try Handoff.publishLatest(path: URL(fileURLWithPath: "/tmp/r.mov"), startedAt: Date(timeIntervalSince1970: 0), duration: 12.5, transcript: nil)
        let data = try Data(contentsOf: folder.appendingPathComponent("latest-recording.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["path"] as? String == "/tmp/r.mov")
        #expect(json["startedAt"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(json["duration"] as? Double == 12.5)
        #expect(json["transcript"] is NSNull)
    }
}

@Suite struct BundleTests {
    @Test func manifestAndTimelineFollowTheSpec() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).watch")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let click = RecordedEvent(hostTime: 105.25, kind: .click(button: "left", x: 0.5, y: 0.25), app: "Safari")
        try Handoff.writeBundle(bundle, createdAt: Date(timeIntervalSince1970: 0), duration: 9, events: [click.json(videoStart: 100)])
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["format"] as? String == "watch-bundle")
        #expect(manifest["version"] as? Int == 1)
        #expect(manifest["video"] as? String == "video.mov")
        let timeline = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("timeline.json"))) as? [String: Any])
        let events = try #require(timeline["events"] as? [[String: Any]])
        #expect(events.first?["t"] as? Double == 5.25)
        #expect(events.first?["type"] as? String == "click")
        #expect(events.first?["app"] as? String == "Safari")
    }

    @Test func clickPositionIsMeasuredFromTheTopLeftOfTheRecordedDisplay() throws {
        let frame = CGRect(x: 100, y: 0, width: 1000, height: 500)
        let point = try #require(normalizedPoint(CGPoint(x: 350, y: 400), in: frame))
        #expect(point.x == 0.25)
        #expect(abs(point.y - 0.2) < 1e-9)
        #expect(normalizedPoint(CGPoint(x: 50, y: 10), in: frame) == nil)
    }

    @Test func eventsBeforeTheFirstFrameStartAtZero() {
        let app = RecordedEvent(hostTime: 99, kind: .app(name: "Xcode"), app: "Xcode")
        let json = app.json(videoStart: 100)
        #expect(json["t"] as? Double == 0)
        #expect(json["name"] as? String == "Xcode")
        #expect(json["app"] == nil)
    }

    @Test func keysBecomeBurstsAndShortcutsWithoutContents() {
        var keys = KeyAggregator()
        for t in [10.0, 10.2, 10.4, 10.6] { keys.key(at: t, modifiers: [], app: "Notes") }
        keys.key(at: 11.0, modifiers: ["cmd"], app: "Notes")
        keys.key(at: 15.0, modifiers: [], app: "Notes")
        keys.flush()
        #expect(keys.events.count == 3)
        if case let .typing(duration, count) = keys.events[0].kind {
            #expect(abs(duration - 0.6) < 1e-9)
            #expect(count == 4)
        } else {
            Issue.record("expected a typing burst")
        }
        #expect(keys.events[1].kind == .shortcut(modifiers: ["cmd"]))
        if case let .typing(_, count) = keys.events[2].kind { #expect(count == 1) } else { Issue.record("expected a typing burst") }
    }
}

@Suite(.serialized) @MainActor struct DeliveryTests {
    @Test func sendToDefaultsToAutoAndPastingIsOptIn() {
        let saved = (Settings.defaults.object(forKey: "SendTo"), Settings.defaults.object(forKey: "AutoPaste"))
        defer {
            Settings.defaults.set(saved.0, forKey: "SendTo")
            Settings.defaults.set(saved.1, forKey: "AutoPaste")
        }
        Settings.defaults.removeObject(forKey: "SendTo")
        Settings.defaults.removeObject(forKey: "AutoPaste")
        #expect(Settings.sendTo == "auto")
        #expect(Settings.autoPaste == false)
    }

    @Test func clipboardOnlyNeverPicksAnApp() {
        let saved = Settings.defaults.object(forKey: "SendTo")
        defer { Settings.defaults.set(saved, forKey: "SendTo") }
        Settings.sendTo = "off"
        #expect(Delivery.resolveTarget(frontmostAtStop: NSRunningApplication.current, lastAIApp: NSRunningApplication.current) == nil)
    }

    @Test func onlyAIAppsAndTerminalsAreTargets() {
        #expect(AIApps.isKnown(NSRunningApplication.current) == false)
        #expect(AIApps.bundleIDs.contains("com.anthropic.claudefordesktop"))
        #expect(AIApps.bundleIDs.contains("com.openai.codex"))
    }
}

@Suite struct QualityTests {
    @Test func keyframesFollowTheServerRules() {
        // Same numbers as defaultBudget in src/watch.ts.
        #expect(Quality.light.keyframes(forSeconds: 60) == 16)
        #expect(Quality.light.keyframes(forSeconds: 600) == 32)
        #expect(Quality.balanced.keyframes(forSeconds: 60) == 32)
        #expect(Quality.detailed.keyframes(forSeconds: 60) == 48)
        #expect(Quality.detailed.keyframes(forSeconds: 3600) == 128)
    }

    @Test func imageTokensAreWholeStoryboards() {
        #expect(Quality.balanced.imageTokens(forSeconds: 60) == 2 * 2128)
        #expect(Quality.detailed.imageTokens(forSeconds: 3600) == 8 * 2128)
    }
}

@Suite(.serialized) @MainActor struct LanguageTests {
    @Test func followsTheChosenLanguage() {
        let saved = Settings.defaults.object(forKey: "AppLanguage")
        defer { Settings.defaults.set(saved, forKey: "AppLanguage") }
        for (language, expected) in [("en", "Record"), ("fr", "Enregistrer"), ("ko", "녹화")] {
            Settings.defaults.set(language, forKey: "AppLanguage")
            #expect(L.t("Record", "Enregistrer", "녹화") == expected)
        }
    }

    @Test func autoFallsBackToALanguageWeHave() {
        let saved = Settings.defaults.object(forKey: "AppLanguage")
        defer { Settings.defaults.set(saved, forKey: "AppLanguage") }
        Settings.defaults.set("auto", forKey: "AppLanguage")
        #expect([AppLanguage.en, .fr, .ko].contains(L.current))
    }
}

@Suite struct MicMeterTests {
    /// AVAudioEngine calls the tap on its own audio queue: it must run there (this crashed before).
    @Test func tapRunsOffTheMainActorAndReportsTheLevel() async {
        let level = await withCheckedContinuation { (done: CheckedContinuation<Double, Never>) in
            DispatchQueue.global().async {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
                      let samples = buffer.floatChannelData?[0] else { return done.resume(returning: -1) }
                buffer.frameLength = 1024
                for i in 0..<1024 { samples[i] = i.isMultiple(of: 2) ? 0.5 : -0.5 }
                MicMeter.tap { level in done.resume(returning: level) }(buffer, AVAudioTime(hostTime: mach_absolute_time()))
            }
        }
        #expect(level > 0.8)
    }
}

