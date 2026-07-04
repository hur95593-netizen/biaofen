// CardViews.swift — 单张牌的正面/背面绘制
import SwiftUI
import BiaofenCore

struct CardFace: View {
    let card: Card
    var width: CGFloat = 54

    private var height: CGFloat { width * 1.45 }
    private var color: Color {
        if card.isJoker {
            return card.rank == BIG_JOKER ? .red : Color(red: 0.15, green: 0.15, blue: 0.2)
        }
        return SuitStyle.isRed(card.suit) ? .red : Color(red: 0.15, green: 0.15, blue: 0.2)
    }

    /// 大王暖红、小王冷蓝 —— 线上棋牌 App 的通行配色,一眼区分
    private var jokerGradient: LinearGradient {
        card.rank == BIG_JOKER
            ? LinearGradient(
                colors: [Color(red: 0.98, green: 0.35, blue: 0.22), Color(red: 0.80, green: 0.10, blue: 0.10)],
                startPoint: .top, endPoint: .bottom
            )
            : LinearGradient(
                colors: [Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.15, green: 0.30, blue: 0.70)],
                startPoint: .top, endPoint: .bottom
            )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.14)
                .fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            RoundedRectangle(cornerRadius: width * 0.14)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)

            if card.isJoker {
                // 左侧竖排字条(重叠只露左边也能认)+ 中央皇冠;大王红 / 小王蓝
                HStack(spacing: 0) {
                    VStack(spacing: width * 0.015) {
                        ForEach(Array((card.rank == BIG_JOKER ? "大王" : "小王").enumerated()), id: \.offset) { _, ch in
                            Text(String(ch))
                                .font(.system(size: width * 0.26, weight: .black))
                        }
                        Text("★")
                            .font(.system(size: width * 0.18, weight: .black))
                    }
                    .foregroundStyle(jokerGradient)
                    .padding(.leading, width * 0.08)
                    .padding(.top, width * 0.08)
                    .frame(maxHeight: .infinity, alignment: .top)
                    Spacer(minLength: 0)
                }

                Image(systemName: "crown.fill")
                    .font(.system(size: width * 0.42))
                    .foregroundStyle(jokerGradient)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, width * 0.10)
                    .padding(.bottom, width * 0.12)
            } else {
                VStack(alignment: .leading, spacing: -width * 0.04) {
                    Text(SuitStyle.rankText(card.rank))
                        .font(.system(size: width * 0.34, weight: .heavy, design: .rounded))
                    Text(SuitStyle.symbol(card.suit))
                        .font(.system(size: width * 0.30))
                }
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, width * 0.10)
                .padding(.top, width * 0.07)

                Text(SuitStyle.symbol(card.suit))
                    .font(.system(size: width * 0.42))
                    .foregroundStyle(color.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, width * 0.10)
                    .padding(.bottom, width * 0.08)
            }
        }
        .frame(width: width, height: height)
    }
}

struct CardBack: View {
    var width: CGFloat = 44

    private var height: CGFloat { width * 1.45 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.14)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.32, blue: 0.65), Color(red: 0.10, green: 0.20, blue: 0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            RoundedRectangle(cornerRadius: width * 0.10)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.2)
                .padding(width * 0.09)
            Text("飙")
                .font(.system(size: width * 0.34, weight: .black))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .frame(width: width, height: height)
    }
}
