// OnlineViews.swift — 联机流程界面:设置页(建房/加入)→ 房间大厅 → 牌桌
import SwiftUI
import BiaofenCore

struct OnlineFlowView: View {
    let vm: OnlineViewModel
    let onExit: () -> Void

    var body: some View {
        switch vm.stage {
        case .setup:
            OnlineSetupView(vm: vm, onExit: onExit)
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                Text("连接服务器中…")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                BarButton(title: "取消", secondary: true) { vm.leaveRoom() }
            }
        case .lobby:
            RoomLobbyView(vm: vm)
        case .playing:
            TableView(vm: vm)
        }
    }
}

// MARK: - 设置页

struct OnlineSetupView: View {
    @Bindable var vm: OnlineViewModel
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("联机对战")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
                )

            HStack(spacing: 10) {
                field("昵称", text: $vm.nickname, width: 150)
                field("服务器(域名或 IP:端口)", text: $vm.serverInput, width: 300)
            }

            HStack(spacing: 14) {
                BarButton(title: "创建 3 人房") { vm.createRoom(players: 3) }
                BarButton(title: "创建 4 人房") { vm.createRoom(players: 4) }

                HStack(spacing: 8) {
                    TextField("房间码", text: $vm.joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 96)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    BarButton(title: "加入", secondary: true) { vm.joinRoom() }
                }
            }

            if let err = vm.errorText {
                Text(err)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45))
            }

            Button {
                onExit()
            } label: {
                Text("← 返回主菜单")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    private func field(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
    }
}

// MARK: - 房间大厅

struct RoomLobbyView: View {
    let vm: OnlineViewModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("房间码")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Text(vm.roomCode)
                    .font(.system(size: 44, weight: .black, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .kerning(6)
                Text("把房间码告诉朋友,同服务器输入即可加入;空位开局时由 AI 补上")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 12) {
                ForEach(0..<vm.players, id: \.self) { seat in
                    lobbySeat(seat)
                }
            }

            HStack(spacing: 14) {
                BarButton(title: "离开房间", secondary: true) { vm.leaveRoom() }
                if vm.isHost {
                    BarButton(title: "开始对局") { vm.startGame() }
                } else {
                    Text("等房主开始…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if let toast = vm.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
    }

    @ViewBuilder
    private func lobbySeat(_ seat: Int) -> some View {
        let taken = vm.seatTaken(seat)
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(taken ? Color(white: 0.35) : Color(white: 0.2).opacity(0.5))
                    .frame(width: 54, height: 54)
                if taken {
                    Image(systemName: seat == vm.humanSeat ? "person.fill" : "person")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(taken ? vm.playerName(seat) : "空位")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(taken ? .white : .white.opacity(0.45))
            if vm.hostSeatIs(seat) {
                Text("房主")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.yellow))
            }
        }
        .frame(width: 92)
    }
}
