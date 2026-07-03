# 飙分 iOS 原生版(SwiftUI)

单机 vs AI + 联机对战,锁横屏,iOS 17+。规则引擎 1:1 移植自 `server/game/`(Go 版),二者行为一致。

## 联机

- 连现有 Go 服务器(`go run ./server -root .`,或线上部署),主菜单 →「联机对战」。
- 服务器地址填 `域名` 或 `IP:端口`(自动补 ws(s):// 和 /ws 路径;本地/局域网走 ws,其余默认 wss)。
- 联机时牌局逻辑全在服务器:客户端渲染按座位打码的视图、本地只做出牌合法性预校验(复用 BiaofenCore)。
- 断线自动带 token 重连回原座位(服务器侧掉线期间 AI 托管)。

## 目录结构

```
ios/
├── project.yml            # xcodegen 工程定义(改动后重新 generate)
├── Biaofen.xcodeproj      # 生成产物,不手改
├── Biaofen/               # App 壳(SwiftUI)
│   ├── BiaofenApp.swift
│   ├── TableVM.swift          # 牌桌协议:单机/联机共用同一套 UI
│   ├── GameViewModel.swift    # 单机:本地引擎 + AI 节奏驱动
│   ├── Online/                # 联机:WebSocket 客户端、服务器消息 DTO、联机 VM、大厅界面
│   └── Views/                 # 菜单、牌桌、卡牌绘制
└── BiaofenCore/           # 规则引擎(独立 Swift Package,可在 macOS 直接跑测试)
    ├── Sources/BiaofenCore/
    │   ├── Cards.swift        # 牌、常主、两套刻度(比大小 / 拖拉机相邻)
    │   ├── Combos.swift       # 牌型识别、压牌、收墩
    │   ├── Follow.swift       # 跟牌合法性(跟大)
    │   ├── GameEngine.swift   # 喊分→亮主→扣底→出牌→结算 状态机
    │   └── AI.swift           # 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分)
    └── Tests/                 # 对照 Go 测试移植,含 300 局×2 全 AI 模拟
```

## 常用命令

```bash
# 跑规则引擎测试(最快,不需要模拟器)
cd ios/BiaofenCore && swift test

# 改了 project.yml 后重新生成工程
cd ios && xcodegen generate

# 命令行构建到模拟器
xcodebuild -project Biaofen.xcodeproj -scheme Biaofen \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

日常开发直接 `open ios/Biaofen.xcodeproj` 用 Xcode 跑。

## 调试启动参数

- `--auto4` / `--auto3`:启动直接开 4/3 人局(单机)
- `--autopilot`:人类座位也由 AI 代打(演示/截图用)
- `--online-demo [--server 127.0.0.1:8124]`:联机自测(自动建房、开局、出牌)

```bash
xcrun simctl launch booted com.biaofen.app --auto4 --autopilot
xcrun simctl launch booted com.biaofen.app --online-demo
```

## 备注

- 免费开发者账号签名 7 天过期,重新构建安装即可
- 真机联机:手机与服务器同一局域网填 `Mac的IP:8124`,或填线上部署域名
