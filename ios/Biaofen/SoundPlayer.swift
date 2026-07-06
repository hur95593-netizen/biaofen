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
            if musicOn { startMusic() } else { musicPlayer?.pause() }
        }
    }

    /// 出牌配音:女声(Tingting)/ 男声(Eddy)/ 关
    enum VoiceMode: String {
        case female = "f", male = "m", off = "off"
    }

    var voiceMode: VoiceMode {
        didSet { UserDefaults.standard.set(voiceMode.rawValue, forKey: "sound.voice") }
    }

    var voiceLabel: String {
        switch voiceMode {
        case .female: return "女"
        case .male: return "男"
        case .off: return "静"
        }
    }

    func cycleVoice() {
        switch voiceMode {
        case .female: voiceMode = .male
        case .male: voiceMode = .off
        case .off: voiceMode = .female
        }
    }

    /// 播报出牌(key 如 s14 / p3 / tractor / throw)
    func announce(_ key: String) {
        guard voiceMode != .off else { return }
        play("\(voiceMode.rawValue)_\(key)")
    }

    private var players: [String: AVAudioPlayer] = [:]
    private var musicPlayer: AVAudioPlayer?

    private init() {
        muted = UserDefaults.standard.bool(forKey: "sound.muted")
        musicOn = UserDefaults.standard.object(forKey: "sound.musicOn") as? Bool ?? true
        voiceMode = VoiceMode(rawValue: UserDefaults.standard.string(forKey: "sound.voice") ?? "f") ?? .female
        // playback:确保 BGM 可靠出声(ambient 在部分场景下会被系统静音)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// App 启动时调用:主菜单和局内都播 BGM(♪ 开关控制)
    func startMusic() {
        guard musicOn else { return }
        if musicPlayer == nil, let url = Bundle.main.url(forResource: "bgm", withExtension: "wav") {
            musicPlayer = try? AVAudioPlayer(contentsOf: url)
            musicPlayer?.numberOfLoops = -1
            musicPlayer?.volume = 0.32 // 衬底,别盖过音效
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        musicPlayer?.play()
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
