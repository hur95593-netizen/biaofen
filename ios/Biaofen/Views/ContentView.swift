// ContentView.swift — 主菜单 ↔ 牌桌切换
import SwiftUI
import BiaofenCore

struct ContentView: View {
    @State private var vm = GameViewModel()

    var body: some View {
        ZStack {
            FeltBackground()
            if vm.inGame {
                TableView(vm: vm)
            } else {
                MenuView(vm: vm)
            }
        }
        .onAppear {
            // 调试/演示用启动参数:--autopilot 人类座位由 AI 代打;--auto3/--auto4 直接开局
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--autopilot") { vm.autopilot = true }
            if args.contains("--auto4") {
                vm.startGame(players: 4)
            } else if args.contains("--auto3") {
                vm.startGame(players: 3)
            }
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
    let vm: GameViewModel

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Text("飙 分")
                    .font(.system(size: 58, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                Text("二七王改编 · 常主 3 与 2 · 单机对战")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 22) {
                MenuButton(title: "3 人局", subtitle: "每人 33 张 · 底牌 9") {
                    vm.startGame(players: 3)
                }
                MenuButton(title: "4 人局", subtitle: "每人 25 张 · 底牌 8") {
                    vm.startGame(players: 4)
                }
            }
        }
    }
}

private struct MenuButton: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(width: 190, height: 86)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
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
