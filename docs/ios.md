# 飙分 iOS 端技术设计

> 总览、规则、三端共通概念见 [README.md](README.md);联机协议细节见 [server.md](server.md)。
> iOS 目录内另有偏"操作手册"性质的 [ios/README.md](../ios/README.md)(构建命令速查),本文偏设计。

## 1. 技术选型与工程形态

- **SwiftUI + Observation(@Observable)**,最低 iOS 17,锁横屏,无第三方依赖,不用游戏引擎(卡牌游戏本质是 UI + 状态机,SwiftUI 足够)。
- **工程由 xcodegen 生成**:`ios/project.yml` 是唯一事实来源,`Biaofen.xcodeproj` 是生成产物(已入库方便直接打开,但改工程配置要改 project.yml 再重新生成,不要在 Xcode 里手改工程设置)。
- **引擎与界面分离**:规则引擎是独立 Swift Package `BiaofenCore`(平台声明含 macOS),所以 `swift test` 在 Mac 上秒级跑完,不需要启动模拟器。

```text
ios/
├── project.yml               # xcodegen 定义:横屏、iOS 17、签名、Info.plist(ATS 允许 ws://)
├── Biaofen/                  # App 壳
│   ├── BiaofenApp.swift      # 入口
│   ├── TableVM.swift         # 牌桌协议 TableVM + 出牌特效 playFeedback(本文核心抽象)
│   ├── GameViewModel.swift   # 单机 ViewModel:本地引擎 + AI 节奏驱动
│   ├── SoundPlayer.swift     # 音效/BGM/震动
│   ├── Online/               # 联机:SocketClient、ServerMessages(DTO)、OnlineViewModel、大厅界面
│   ├── Views/                # ContentView(菜单/路由)、TableView(牌桌)、CardViews(卡面)
│   └── Sounds/*.wav          # 程序合成的音效与 BGM
└── BiaofenCore/              # 规则引擎 Package
    ├── Sources/BiaofenCore/  # Cards / Combos / Follow / GameEngine / AI
    └── Tests/                # 与 Go 同套用例 + 300 局 ×2 模拟
```

## 2. BiaofenCore:规则引擎(Swift 版)

与 Go 版逐文件、逐函数对齐,读法完全参照 [README.md](README.md) 第 5 节 + [server.md](server.md):

| Swift 文件 | 对应 Go 文件 | 备注 |
|-----------|--------------|------|
| Cards.swift | server/game/cards.go | Card 是 struct,id 为计算属性(格式与协议一致);内含 SeededRNG(可播种,测试可复现)与 stableSorted(对齐 Go 的 sort.SliceStable) |
| Combos.swift | combos.go | ComboType 枚举 rawValue 与协议字符串一致(single/pair/tractor/throw,Swift 侧 case 名为 throwLead) |
| Follow.swift | follow.go | isLegalFollow 等 |
| GameEngine.swift | game.go | Game 类(状态机)、validThrow 甩牌校验、结算 |
| AI.swift | ai.go | 完整 AI + 联机提示用的 suggestLead/suggestFollow(只依赖本视角可见信息) |

**Codable 对齐**:Card/Combo/Play/Trick/HandResult 都实现 Codable 且字段名与服务器 JSON 完全一致(Combo.pairs 对齐 Go 的 omitempty,缺省解码为 0),这就是联机 DTO 能直接复用引擎类型的原因。

## 3. UI 架构:TableVM 协议(单机/联机共用一套界面)

本端最重要的设计:牌桌界面 `TableView<VM: TableVM>` 是泛型,不关心数据从哪来。协议 `TableVM` 定义了牌桌需要的全部只读状态(phase/myHand/trickPlays/scores/result/kittyIDs/buriedCards/playEffect…)和操作(humanBid/humanDeclare/humanBury/humanPlay/hint/toggleSelect/setSelect…)。两个实现:

### 3.1 GameViewModel(单机)

- **快照模式**:私有持有 BiaofenCore 的 Game 引擎;每次操作后 `refresh()` 把引擎状态整体拷贝到 @Observable 的存储属性上驱动 UI(引擎本身不是 Observable,避免耦合)。
- **AI 驱动**:`runAILoop()` 异步循环——轮到电脑就 sleep 一个拟人延迟(喊分 600ms/亮主 700ms/出牌 650ms)再执行 AI 函数;轮到人类就 return 等待界面操作;人类操作后重新 driveAI()。
- **节奏控制**:收墩后整墩留在 displayTrick 上(下一圈有人出牌才清);终局用 holdResult 把结算面板压后约 2 秒,先让玩家看清最后一墩,结算面板里翻开底牌(buriedCards)。
- **调试自动驾驶**:autopilot=true 时人类座位也由 AI 代打(端到端自测用)。

### 3.2 OnlineViewModel(联机)

- **无本地引擎**:全部 TableVM 属性都是对服务器视图 RoomState 的映射;操作全部转成 WebSocket 消息上行。
- **本地预校验**:出牌按钮的可用态用 BiaofenCore 的 detectCombo/isLegalFollow 就地判断(不用请求服务器);甩牌因客户端没有全量记牌信息,多张主牌先放行、由服务器裁决。
- **断线重连**:joined 时收到的 token 保存;连接断开且在局中时按 1.5s × 次数退避自动重连(最多 5 次),带 token 回到原座位;期间服务器侧 AI 托管。
- **提示**:调 BiaofenCore 的 suggestLead/suggestFollow(只用手牌 + 当前墩,不依赖历史)。
- 房间流程分四个 stage:setup(填昵称/服务器/房间码)→ connecting → lobby(房间码大字 + 座位表 + 房主开局)→ playing(进 TableView)。

### 3.3 网络层

- `SocketClient`:URLSessionWebSocketTask 薄封装,回调统一切回主线程;`normalize()` 把用户输入的"域名或 IP:端口"补全成 ws(s)://…/ws(本地/局域网走 ws,其余默认 wss)。
- `ServerMessages.swift`:协议 DTO(OutMsg 上行;JoinedMsg/RoomState/EventMsg 下行),字段与 [server.md](server.md) 协议表一一对应,RoomState 全部字段可空以容忍服务器的 null。
- Info.plist 已开 ATS 例外(NSAllowsArbitraryLoads)以允许 ws:// 明文连本地/局域网服务器;云端建议 wss。

## 4. 界面组成(Views/)

| 组件 | 说明 |
|------|------|
| ContentView | 路由:menu / single / online 三屏;解析调试启动参数;主菜单右上角音乐/音效开关 |
| TableView | 牌桌总装:顶栏(房号/局数/主花色/喊分/闲家分/积分/静音/回菜单)、对手位(上/左/右)、中央出牌区 TrickLayer、特效层 EffectLayer(拖拉机开过/甩牌弹字)、操作栏 ActionBar(按阶段切换:喊分调档器/亮主花色钮/扣底计数/提示+出牌)、结算面板 ResultOverlay(含翻底牌) |
| MyHandView | 手牌扇:按可用宽度动态计算重叠步长;单指 DragGesture 同时实现点选与滑动批量选牌(按下首张的状态决定这一划是选还是取消);扣底阶段底牌带"底"角标 |
| CardViews | CardFace(角标左上锚定,重叠也可辨;大小王为左侧竖排字条 + 皇冠,大王红/小王蓝)与 CardBack |

## 5. 音效(SoundPlayer)

- 单例 @Observable;AVAudioSession 用 **playback** 类别(注意:曾用 ambient 导致模拟器/静音开关下无声,这是一个已踩过的坑)。
- 音效 wav(选牌/出牌/收墩/喊分/亮主/胜/负/发牌/轮到你)与 16 秒循环 BGM 全部由脚本程序合成,无版权素材;BGM 只受音乐开关控制,音效受静音开关控制,均持久化。
- 真机附带震动反馈(选牌轻震/出牌中震/结算中震)。

## 6. 构建、运行、装机

```bash
# 引擎测试(最常用,秒级,不需要模拟器)
cd ios/BiaofenCore && swift test

# 改了 project.yml 或增删源文件/资源后,重新生成工程
cd ios && xcodegen generate

# 命令行构建到模拟器并安装启动
xcodebuild -project Biaofen.xcodeproj -scheme Biaofen \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Biaofen.app
xcrun simctl launch booted com.biaofen.app

# 真机(需要连线;签名走自动签名)
xcodebuild -project Biaofen.xcodeproj -scheme Biaofen \
  -destination 'generic/platform=iOS' -derivedDataPath build-device -allowProvisioningUpdates build
xcrun devicectl device install app --device <设备ID> build-device/Build/Products/Debug-iphoneos/Biaofen.app
```

> **签名注意**:当前用免费个人开发者账号(DEVELOPMENT_TEAM 见 project.yml),描述文件 **7 天过期**,过期后 App 打不开、重新构建安装即可;要长期安装/上架需付费开发者账号。曾踩坑:证书名括号里的串不是 Team ID,真实 Team ID 在证书的 OU 字段。

**调试启动参数**(simctl launch 追加):`--auto3 / --auto4` 直接开单机局;`--autopilot` 人类座位 AI 代打;`--online-demo [--server 127.0.0.1:8124]` 联机全自动自测(建房 + 开局 + 自动出牌)。日常联机手测:先 `go run ./server -root .`,模拟器里服务器地址填 127.0.0.1:8124;多开模拟器可互相对战。

## 7. 常见维护任务怎么做

| 任务 | 改哪里 |
|------|--------|
| 改牌桌 UI | Views/ 对应组件;因 TableView 是泛型,单机联机一次生效 |
| 改规则/AI | 先 Go 后同步 BiaofenCore(函数一一对应照抄),swift test 全绿;界面层通常不用动 |
| 加音效 | 合成脚本生成 wav 放 Sounds/,xcodegen generate 重新收资源,SoundPlayer.play("名字") 挂到事件点 |
| 加联机字段 | server view.go 加字段 → ServerMessages.RoomState 加同名可空属性 → OnlineViewModel 映射 |
| 排查界面不刷新 | 检查 GameViewModel.refresh() 是否把新状态拷进了快照属性(引擎字段改了但没进快照是最常见原因) |
