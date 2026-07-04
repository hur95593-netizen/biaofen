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

    var musicOn: Bool {
        didSet {
            UserDefaults.standard.set(musicOn, forKey: "sound.musicOn")
            if musicOn { startMusic() } else { stopMusic() }
        }
    }

    private var players: [String: AVAudioPlayer] = [:]
    private var musicPlayer: AVAudioPlayer?
    private var inGame = false

    private init() {
        muted = UserDefaults.standard.bool(forKey: "sound.muted")
        musicOn = UserDefaults.standard.object(forKey: "sound.musicOn") as? Bool ?? true
        // ambient:跟随静音键、不打断用户正在听的音乐
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// 进入/离开牌局时调用:BGM 只在局内播放
    func setInGame(_ on: Bool) {
        inGame = on
        if on && musicOn { startMusic() } else { stopMusic() }
    }

    private func startMusic() {
        guard inGame, musicOn else { return }
        if musicPlayer == nil, let url = Bundle.main.url(forResource: "bgm", withExtension: "wav") {
            musicPlayer = try? AVAudioPlayer(contentsOf: url)
            musicPlayer?.numberOfLoops = -1
            musicPlayer?.volume = 0.22 // 衬底,别盖过音效
        }
        musicPlayer?.play()
    }

    private func stopMusic() {
        musicPlayer?.pause()
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
