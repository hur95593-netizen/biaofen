// TableView.swift — 横屏牌桌:顶栏 + 对手 + 中央出牌区 + 手牌扇 + 操作栏 + 结算面板
// 泛型于 TableVM:单机(GameViewModel)与联机(OnlineViewModel)共用
import SwiftUI
import BiaofenCore

struct TableView<VM: TableVM>: View {
    let vm: VM

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(vm: vm)
                Spacer(minLength: 0)
                ActionBar(vm: vm)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                MyHandView(vm: vm)
                    .frame(height: 106)
                    .padding(.bottom, 4)
            }

            opponents

            TrickLayer(vm: vm)
                .offset(y: -8)

            if let fx = vm.playEffect {
                EffectLayer(effect: fx)
                    .id(fx.id)
                    .allowsHitTesting(false)
            }

            if let toast = vm.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
                    .transition(.opacity)
            }

            if let r = vm.result {
                ResultOverlay(vm: vm, r: r)
            }
        }
        .animation(.easeOut(duration: 0.2), value: vm.toast != nil)
    }

    @ViewBuilder
    private var opponents: some View {
        let right = (vm.humanSeat + 1) % vm.players
        OpponentView(vm: vm, seat: right)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            .offset(y: -34)

        if vm.players == 4 {
            let top = (vm.humanSeat + 2) % vm.players
            let left = (vm.humanSeat + 3) % vm.players
            OpponentView(vm: vm, seat: top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 44)
            OpponentView(vm: vm, seat: left)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .offset(y: -34)
        } else {
            let left = (vm.humanSeat + 2) % vm.players
            OpponentView(vm: vm, seat: left)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .offset(y: -34)
        }
    }
}

// MARK: - 顶栏

struct TopBar<VM: TableVM>: View {
    let vm: VM

    var body: some View {
        HStack(spacing: 14) {
            if let badge = vm.roomBadge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.35)))
            }

            Text("第 \(vm.handNo) 局")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 4) {
                Text("主")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                if vm.trumpSuit.isEmpty {
                    Text("未定")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(SuitStyle.symbol(vm.trumpSuit))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SuitStyle.isRed(vm.trumpSuit) ? Color(red: 1, green: 0.45, blue: 0.42) : .white)
                }
            }

            if vm.contract > 0 {
                Text("喊分 \(vm.contract) · 线 \(200 - vm.contract)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("闲家 \(vm.xianPoints) 分")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.yellow)
            }

            Spacer()

            ForEach(0..<vm.players, id: \.self) { seat in
                let s = vm.scores.indices.contains(seat) ? vm.scores[seat] : 0
                Text("\(vm.playerName(seat)) \(s > 0 ? "+\(s)" : "\(s)")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(s > 0 ? .green : (s < 0 ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.8)))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.25)))
                    .lineLimit(1)
            }

            Button {
                SoundPlayer.shared.cycleVoice() // 配音:女 → 男 → 关
            } label: {
                Text(SoundPlayer.shared.voiceLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SoundPlayer.shared.voiceMode == .off ? .white.opacity(0.4) : .yellow)
                    .frame(width: 16, height: 16)
                    .padding(5)
                    .background(Circle().fill(.black.opacity(0.3)))
            }
            .buttonStyle(.plain)

            Button {
                SoundPlayer.shared.musicOn.toggle()
            } label: {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(SoundPlayer.shared.musicOn ? .yellow : .white.opacity(0.4))
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.3)))
            }
            .buttonStyle(.plain)

            Button {
                SoundPlayer.shared.muted.toggle()
            } label: {
                Image(systemName: SoundPlayer.shared.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.3)))
            }
            .buttonStyle(.plain)

            Button {
                vm.backToMenu()
            } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.3)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.28))
    }
}

// MARK: - 对手

struct OpponentView<VM: TableVM>: View {
    let vm: VM
    let seat: Int

    private var isTurn: Bool {
        (vm.phase == .play && vm.turn == seat)
            || (vm.phase == .bidding && vm.bidTurn == seat)
    }

    private var connected: Bool { vm.seatConnected(seat) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.45), Color(white: 0.25)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: vm.seatIsBot(seat) ? "cpu.fill" : "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(connected ? 0.85 : 0.35))
                if !connected {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .offset(x: 16, y: -16)
                }
                if isTurn {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: 50, height: 50)
                }
            }
            .opacity(connected ? 1 : 0.75)

            HStack(spacing: 4) {
                Text(vm.playerName(seat))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 90)
                if vm.declarer == seat && vm.phase != .bidding {
                    Text("庄")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.orange))
                }
            }

            let count = vm.handCounts.indices.contains(seat) ? vm.handCounts[seat] : 0
            HStack(spacing: 3) {
                CardBack(width: 15)
                Text("×\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if vm.phase == .bidding {
                if vm.passed.indices.contains(seat), vm.passed[seat] {
                    bubble("不喊", color: .gray)
                } else if vm.highBidder == seat {
                    bubble("喊 \(vm.highBid)", color: .orange)
                }
            }
        }
    }

    private func bubble(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.9)))
    }
}

// MARK: - 牌型出场特效

struct EffectLayer: View {
    let effect: PlayEffect

    var body: some View {
        switch effect.kind {
        case .tractor:
            TractorFx()
        case .throwCards:
            ThrowFx()
        }
    }
}

/// 拖拉机:开过牌桌中央
private struct TractorFx: View {
    @State private var x: CGFloat = -320

    var body: some View {
        HStack(spacing: 8) {
            Text("拖拉机!")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            Text("🚜")
                .font(.system(size: 44))
                .scaleEffect(x: -1) // 车头朝右
                .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
        }
        .offset(x: x, y: -10)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5)) { x = 320 }
        }
    }
}

/// 甩牌:大字弹出
private struct ThrowFx: View {
    @State private var scale: CGFloat = 0.3
    @State private var opacity: CGFloat = 0

    var body: some View {
        Text("甩牌!")
            .font(.system(size: 40, weight: .black, design: .rounded))
            .foregroundStyle(
                LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(y: -14)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                    scale = 1.15
                    opacity = 1
                }
                withAnimation(.easeOut(duration: 0.4).delay(1.1)) {
                    opacity = 0
                }
            }
    }
}

// MARK: - 中央出牌区

struct TrickLayer<VM: TableVM>: View {
    let vm: VM

    var body: some View {
        let plays: [Play] = vm.displayTrick?.plays ?? vm.trickPlays
        let winner = vm.displayTrick?.winnerSeat
        ZStack {
            ForEach(plays.indices, id: \.self) { idx in
                let p = plays[idx]
                PlayRow(cards: p.cards, highlighted: p.seat == winner)
                    .offset(offsetFor(vm.relPosition(p.seat)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: plays.count)
    }

    private func offsetFor(_ rel: Int) -> CGSize {
        if vm.players == 4 {
            switch rel {
            case 0: return CGSize(width: 0, height: 70)
            case 1: return CGSize(width: 165, height: -2)
            case 2: return CGSize(width: 0, height: -44) // 避开顶部玩家的名牌
            default: return CGSize(width: -165, height: -2)
            }
        }
        switch rel {
        case 0: return CGSize(width: 0, height: 70)
        case 1: return CGSize(width: 155, height: -22)
        default: return CGSize(width: -155, height: -22)
        }
    }
}

struct PlayRow: View {
    let cards: [Card]
    let highlighted: Bool

    var body: some View {
        HStack(spacing: -13) {
            ForEach(cards) { c in
                CardFace(card: c, width: 38)
            }
        }
        .overlay(alignment: .topTrailing) {
            if highlighted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.yellow)
                    .offset(x: 8, y: -8)
            }
        }
        .shadow(color: highlighted ? .yellow.opacity(0.85) : .clear, radius: 7)
    }
}

// MARK: - 我的手牌

struct MyHandView<VM: TableVM>: View {
    let vm: VM
    @State private var dragMode: Bool? // 滑动选牌:按下首张牌决定本次是"选中"还是"取消"

    var body: some View {
        GeometryReader { geo in
            let n = vm.myHand.count
            if n > 0 {
                let cardW: CGFloat = 56
                let cardH: CGFloat = cardW * 1.45
                let maxSpread = geo.size.width - 24
                let step: CGFloat = n > 1 ? min(cardW * 0.62, (maxSpread - cardW) / CGFloat(n - 1)) : 0
                let total = cardW + step * CGFloat(n - 1)
                let startX = (geo.size.width - total) / 2

                ZStack {
                    ForEach(Array(vm.myHand.enumerated()), id: \.element.id) { i, card in
                        let isSel = vm.selected.contains(card.id)
                        CardFace(card: card, width: cardW)
                            .overlay(
                                RoundedRectangle(cornerRadius: cardW * 0.14)
                                    .strokeBorder(isSel ? Color.yellow : .clear, lineWidth: 2.5)
                            )
                            .overlay(alignment: .top) {
                                if vm.phase == .kitty && vm.kittyIDs.contains(card.id) {
                                    Text("底")
                                        .font(.system(size: 10, weight: .black))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.orange))
                                        .offset(y: -9)
                                }
                            }
                            .position(
                                x: startX + cardW / 2 + CGFloat(i) * step,
                                y: geo.size.height - cardH / 2 + (isSel ? -16 : 0)
                            )
                            .zIndex(Double(i))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                // 单指按下/滑动都走同一手势:点一下=切换一张,划过去=批量选
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard vm.canSelectCards, n > 0 else { return }
                            let rel = v.location.x - startX
                            guard rel >= -6, rel <= total + 6 else { return }
                            let idx = max(0, min(n - 1, Int(rel / max(step, 1))))
                            let card = vm.myHand[idx]
                            let mode = dragMode ?? !vm.selected.contains(card.id)
                            dragMode = mode
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                vm.setSelect(card, mode)
                            }
                        }
                        .onEnded { _ in dragMode = nil }
                )
            }
        }
    }
}

// MARK: - 操作栏

struct ActionBar<VM: TableVM>: View {
    let vm: VM
    @State private var bidAmount = 0 // 跳喊选档;shownBid 用 max 自愈,轮次变化时重置

    private var shownBid: Int {
        min(max(bidAmount, vm.nextBidLevel), 200)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(vm.statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()

            switch vm.phase {
            case .bidding:
                if vm.bidTurn == vm.humanSeat {
                    BarButton(title: "不喊", secondary: true) { vm.humanBid(0) }
                    // 任意跳喊:±10 调档后一键喊出(只要高于当前价,想喊多少喊多少)
                    stepButton("minus") { bidAmount = max(shownBid - 10, vm.nextBidLevel) }
                    Text("\(shownBid)")
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .frame(width: 44)
                    stepButton("plus") { bidAmount = min(shownBid + 10, 200) }
                    BarButton(title: "喊 \(shownBid)") { vm.humanBid(shownBid) }
                }
            case .declare:
                if vm.declarer == vm.humanSeat {
                    ForEach(SUITS, id: \.self) { s in
                        Button {
                            vm.humanDeclare(s)
                        } label: {
                            Text(SuitStyle.symbol(s))
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(SuitStyle.isRed(s) ? .red : Color(red: 0.15, green: 0.15, blue: 0.2))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(.white))
                                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .kitty:
                if vm.declarer == vm.humanSeat {
                    Text("\(vm.selected.count)/\(vm.kittySize)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(vm.selected.count == vm.kittySize ? .yellow : .white.opacity(0.7))
                    BarButton(title: "确认扣底", disabled: vm.selected.count != vm.kittySize) { vm.humanBury() }
                }
            case .play:
                if vm.turn == vm.humanSeat {
                    if vm.supportsHint {
                        BarButton(title: "提示", secondary: true) {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { vm.hint() }
                        }
                    }
                    BarButton(title: "出牌", disabled: !vm.canPlaySelection) { vm.humanPlay() }
                }
            case .idle, .done:
                EmptyView()
            }
        }
        .frame(height: 46)
        .onChange(of: vm.bidTurn) { _, _ in bidAmount = 0 }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

struct BarButton: View {
    let title: String
    var secondary = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(
                        secondary
                            ? AnyShapeStyle(Color.white.opacity(0.22))
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color(red: 0.95, green: 0.60, blue: 0.12), Color(red: 0.85, green: 0.42, blue: 0.05)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                )
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - 结算面板

struct ResultOverlay<VM: TableVM>: View {
    let vm: VM
    let r: HandResult

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 12) {
                Text(r.label)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(r.perXian > 0 ? Color.green : (r.perXian < 0 ? Color.orange : Color.white))

                Text("喊分 \(r.contract) · 闲家线 \(r.line) · 底分 \(r.stake)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 4) {
                    Text("闲家捡分 \(r.xianPoints)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.yellow)
                    if r.lastTrickBonus > 0 {
                        Text("(含翻底 +\(r.lastTrickBonus))")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow.opacity(0.8))
                    }
                }

                if !vm.buriedCards.isEmpty {
                    let kittyPts = vm.buriedCards.reduce(0) { $0 + pointValue($1) }
                    VStack(spacing: 5) {
                        Text("底牌翻开(\(kittyPts) 分\(r.lastTrickBonus > 0 ? ",已被闲家翻走" : ",归庄家"))")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                        HStack(spacing: -10) {
                            ForEach(vm.buriedCards.sorted {
                                (pointValue($0), $0.rank) > (pointValue($1), $1.rank)
                            }) { c in
                                CardFace(card: c, width: 34)
                            }
                        }
                    }
                }

                VStack(spacing: 6) {
                    ForEach(0..<vm.players, id: \.self) { seat in
                        HStack {
                            HStack(spacing: 5) {
                                Text(vm.playerName(seat))
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                if seat == r.declarer {
                                    Text("庄")
                                        .font(.system(size: 10, weight: .black))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Circle().fill(.orange))
                                }
                            }
                            Spacer()
                            let d = r.deltas.indices.contains(seat) ? r.deltas[seat] : 0
                            Text(d > 0 ? "+\(d)" : "\(d)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(d > 0 ? .green : (d < 0 ? .red : .secondary))
                            Text("累计 \(r.scores.indices.contains(seat) ? r.scores[seat] : 0)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 4)

                HStack(spacing: 14) {
                    BarButton(title: "回菜单", secondary: true) { vm.backToMenu() }
                    BarButton(title: "下一局") { vm.newHand() }
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 380)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.12, green: 0.16, blue: 0.14))
                    .shadow(color: .black.opacity(0.5), radius: 16)
            )
        }
    }
}
