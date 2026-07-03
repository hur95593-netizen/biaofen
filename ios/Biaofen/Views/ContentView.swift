// ContentView.swift — 主菜单 ↔ 单机牌桌 ↔ 联机流程
import SwiftUI
import BiaofenCore

struct ContentView: View {
    enum Screen {
        case menu, single, online
    }

    @State private var screen: Screen = .menu
    @State private var gameVM = GameViewModel()
    @State private var onlineVM = OnlineViewModel()

    var body: some View {
        ZStack {
            FeltBackground()
            switch screen {
            case .menu:
                MenuView(
                    onSingle: { players in
                        gameVM.startGame(players: players)
                        screen = .single
                    },
                    onOnline: { screen = .online }
                )
            case .single:
                TableView(vm: gameVM)
            case .online:
                OnlineFlowView(vm: onlineVM) { screen = .menu }
            }
        }
        .onChange(of: gameVM.inGame) { _, inGame in
            if !inGame && screen == .single { screen = .menu }
        }
        .onAppear(perform: handleLaunchArgs)
    }

    /// 调试/演示用启动参数:--autopilot 人类座位由 AI 代打;--auto3/--auto4 直接开单机局;
    /// --online-demo [--server ws://…] 联机自测(建房+开局+自动出牌)
    private func handleLaunchArgs() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--autopilot") { gameVM.autopilot = true }
        if args.contains("--auto4") {
            gameVM.startGame(players: 4)
            screen = .single
        } else if args.contains("--auto3") {
            gameVM.startGame(players: 3)
            screen = .single
        } else if args.contains("--online-demo") {
            var server = "127.0.0.1:8124"
            if let i = args.firstIndex(of: "--server"), args.indices.contains(i + 1) {
                server = args[i + 1]
            }
            screen = .online
            onlineVM.startDemo(server: server)
        }
    }
}

struct FeltBackground: View {
    var body: some View {
        RadialGradient(
            colors: [
                Color(red: 0.07, green: 0.42, blue: 0.27),
                Color(red: 0.02, green: 0.24, blue: 0.15),
            ],
            center: .center, startRadius: 60, endRadius: 560
        )
        .ignoresSafeArea()
    }
}

struct MenuView: View {
    let onSingle: (Int) -> Void
    let onOnline: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("飙 分")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                Text("二七王改编 · 常主 3 与 2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 18) {
                MenuButton(title: "3 人局", subtitle: "单机 · 每人 33 张") {
                    onSingle(3)
                }
                MenuButton(title: "4 人局", subtitle: "单机 · 每人 25 张") {
                    onSingle(4)
                }
                MenuButton(title: "联机对战", subtitle: "房间码开房 · 真人+AI", accent: true) {
                    onOnline()
                }
            }
        }
    }
}

private struct MenuButton: View {
    let title: String
    let subtitle: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(width: 170, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        accent
                            ? LinearGradient(
                                colors: [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.10, green: 0.38, blue: 0.80)],
                                startPoint: .top, endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [Color(red: 0.95, green: 0.60, blue: 0.12), Color(red: 0.85, green: 0.42, blue: 0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            )
        }
        .buttonStyle(.plain)
    }
}
