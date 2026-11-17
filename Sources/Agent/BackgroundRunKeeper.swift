import Foundation
#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation
#endif

/// Keeps the app running while the agent works.
///
/// Controlling the iPhone means leaving iSyCode (the agent opens another app, or waits for an
/// approval that arrives as a notification). Without this, iOS suspends the app a few seconds
/// after it leaves the screen and the model call is cut. While at least one agent turn is
/// running we hold a short background task and a silent, mixable audio session (the
/// `audio` background mode), which keeps the process alive without interrupting other audio.
///
/// Limits: the on-device llama model uses the GPU, which iOS forbids in the background, so this
/// is for remote models and tool work. It is released the moment the last turn ends.
public final class BackgroundRunKeeper: @unchecked Sendable {
    public static let shared = BackgroundRunKeeper()

    /// Main-queue only.
    private var holders = 0
    #if canImport(UIKit) && canImport(AVFoundation)
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    #endif

    public func begin() {
        DispatchQueue.main.async {
            self.holders += 1
            if self.holders == 1 { self.start() }
        }
    }

    public func end() {
        DispatchQueue.main.async {
            guard self.holders > 0 else { return }
            self.holders -= 1
            if self.holders == 0 { self.stop() }
        }
    }

    #if canImport(UIKit) && canImport(AVFoundation)
    private func start() {
        task = UIApplication.shared.beginBackgroundTask(withName: "iyscode.agent-run") { [weak self] in
            self?.releaseTask()
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence())
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // The background task above still gives a short grace period.
            player = nil
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.holders > 0,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.player?.play()
        }
    }

    private func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        releaseTask()
    }

    private func releaseTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    /// One second of 8 kHz mono 16-bit PCM silence as a WAV file.
    static func silence() -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = Int(sampleRate)
        let dataSize = UInt32(samples * 2)
        var wav = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
        wav.append(contentsOf: Array("data".utf8)); put32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }
    #else
    private func start() {}
    private func stop() {}
    #endif
}
