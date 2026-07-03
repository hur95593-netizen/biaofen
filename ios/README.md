# 飙分 iOS 原生版(SwiftUI)

单机 vs AI,锁横屏,iOS 17+。规则引擎 1:1 移植自 `server/game/`(Go 版),二者行为一致。

## 目录结构

```
ios/
├── project.yml            # xcodegen 工程定义(改动后重新 generate)
├── Biaofen.xcodeproj      # 生成产物,不手改
├── Biaofen/               # App 壳(SwiftUI)
│   ├── BiaofenApp.swift
│   ├── GameViewModel.swift    # 界面状态 + AI 节奏驱动
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

- `--auto4` / `--auto3`:启动直接开 4/3 人局
- `--autopilot`:人类座位也由 AI 代打(演示/截图用)

```bash
xcrun simctl launch booted com.biaofen.app --auto4 --autopilot
```

## 后续(二期)

- 联机:复用现有 Go 服务器(WebSocket),`Card` 的 JSON 字段已与前后端一致
- 真机安装 / 上架需在 Xcode 里配置开发者账号签名
