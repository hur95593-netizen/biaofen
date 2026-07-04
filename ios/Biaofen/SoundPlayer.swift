// SoundPlayer.swift — 音效 + 震动反馈(素材为程序合成的 WAV,与 Web 版 sfx.js 同参数)
import AVFoundation
import SwiftUI
import Observation

@MainActor
@Observable
final class SoundPlayer {
    static let shared = SoundPlayer()

    var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "sound.muted") }
    }

    private var players: [String: AVAudioPlayer] = [:]

    private init() {
        muted = UserDefaults.standard.bool(forKey: "sound.muted")
        // ambient:跟随静音键、不打断用户正在听的音乐
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// name ∈ select | play | trick | bid | trump | win | lose
    func play(_ name: String) {
        guard !muted else { return }
        if players[name] == nil,
           let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
            players[name]?.prepareToPlay()
        }
        guard let p = players[name] else { return }
        p.currentTime = 0
        p.play()
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
