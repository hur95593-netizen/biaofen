# 飙分 服务端技术设计(Go)

> 总览、规则、三端共通概念见 [README.md](README.md)。服务端同时是**规则引擎与 AI 的移植蓝本**——改逻辑先改这里。

## 1. 技术选型与形态

**Go + gorilla/websocket,单二进制部署**:前端静态文件通过 go:embed 内嵌(embed.go),`go build` 出来的一个可执行文件就是完整服务(静态托管 + WebSocket)。无数据库、无缓存、无外部依赖——对局是短生命周期的内存状态,房间解散即消失,这符合"朋友开房打牌"的产品形态,也让部署和运维几乎为零。

```text
server/
├── main.go      # 入口:/ws 升级 WebSocket,其余路径托管静态文件;-addr/-root 参数,PORT 环境变量
├── hub.go       # Hub:房间码 -> Room 的注册表(带锁),生成不易混淆的 4 位房间码
├── client.go    # 一条连接的读/写泵(gorilla 标准模式);ClientMsg 定义了客户端全部上行消息
├── room.go      # 一桌 = 一个 goroutine 的事件循环(本文核心,见第 3 节)
├── view.go      # 按座位打码的对局视图(防作弊关键,见第 4 节)
└── game/        # 规则引擎 + AI(与 Web/iOS 三端对齐)
    ├── cards.go combos.go follow.go game.go   # 牌/牌型/跟牌/状态机(概念见总览第 5 节)
    ├── ai.go                                   # 电脑玩家(见第 5 节)
    ├── engine_test.go follow_test.go sim_test.go  # 规则用例 + 300 局 ×2 模拟
    └── ab_test.go                              # AI 策略 A/B 对战台(见 5.4)
```

## 2. 连接层(client.go)

每条 WebSocket 连接两个 goroutine:readPump(读消息、心跳读超时 60s、Pong 续期)和 writePump(写消息、每 45s 发 Ping)。慢客户端发送缓冲满时直接断开,防止拖垮整桌。连接的第一条消息必须是 create 或 join,之后消息全部投递给所属房间处理。不校验 Origin(局域网 IP 直连场景),身份靠房间 token 而非 Cookie。

## 3. 房间并发模型(room.go):一房一 goroutine 的 actor

**这是服务端最重要的设计。**每个房间一个 goroutine 跑事件循环,所有牌局状态只被这个 goroutine 触碰,因此**整个牌局逻辑零锁、天然串行**;房间之间完全独立,天然横向并发。任何其他 goroutine(连接读泵、AI 定时器)想动房间,只能往 inbox channel 投事件:

| 事件 | 来源 | 处理 |
|------|------|------|
| evJoin | 连接层 | 带 token 则重连回原座位(新连接顶掉旧连接);否则占一个空位并发 joined(座位号 + 新 token) |
| evMsg | 连接层 | start/bid/trump/bury/play/next,逐条校验(房主才能开局、庄家才能亮主扣底、牌必须在手中),非法回 error,合法则更新状态并广播 |
| evClose | 连接断开 | 大厅阶段直接让座;对局中保留座位、转 AI 托管(给 3 秒重连窗口) |
| evBot | AI 定时器 | 轮到电脑/掉线者时执行 AI 动作;botSeq 递增序号用来作废过期定时器(状态变了旧定时器自动失效) |

其他机制:房主 = 座位号最小的真人;开局时空位自动 AI 补位;AI 动作有拟人延迟(喊分 600ms、出牌 700ms、收墩后 1600ms 让真人看清上一墩,掉线托管额外等 3s);每分钟检查一次,无真人在线超过 10 分钟房间自动解散。

## 4. WebSocket 协议

### 4.1 客户端上行(ClientMsg,JSON,按 type 取字段)

| type | 字段 | 说明 |
|------|------|------|
| create | players(3/4), name | 建房,返回 joined |
| join | room, name, token(可选) | 入房;带 token = 断线重连回原座位 |
| start | - | 房主开局,空位 AI 补位 |
| bid | amount | 喊分;0 = 不喊;100~200 的 10 倍数且高于当前最高(可跳喊) |
| trump | suit(S/H/D/C) | 庄家亮主 |
| bury | ids[] | 庄家扣底(牌一律用 id 列表,如 "S-5-0") |
| play | ids[] | 出牌;合法性全部由服务器校验 |
| next | - | 结算后开下一局 |

### 4.2 服务器下行

| type | 内容 |
|------|------|
| joined | room(房间码)、seat(座位号)、token(重连凭证,客户端要保存)、players |
| state | 完整视图(见 4.3),任何状态变化后对每个座位分别生成并推送 |
| event | 轻量事件流,供客户端弹提示:kind = joined/left/disconnected/reconnected/bid/declarerSet/trump/buried/trick/result,附 seat 和按 kind 取义的 data |
| error | msg(人话错误,如"房间已满""出牌不合法") |

### 4.3 state 视图与打码规则(view.go)

字段分三层:房间层(seats 各座位的 taken/bot/name/connected、hostSeat、mySeat)、进程层(phase/handNo/scores、喊分四件套 bidTurn/highBid/highBidder/passed、declarer/contract/trumpSuit)、牌桌层(turn/leader、trickPlays、lastTrick、tricksPlayed、xianPoints/xianCaptured、result)。**打码规则**:

- hand 只包含收件人自己的手牌;他人只有 counts(张数)。
- kittyIds 仅在扣底阶段发给庄家本人(界面标记哪些是底牌)。
- buried(底牌)仅在 phase=done 时下发(结算翻底)。
- 数值型"空"统一用 -1,phase 为空串表示大厅,客户端好判断。

## 5. AI(game/ai.go)

AI 与规则引擎同包,三端逐函数对齐。整体是**带记牌的启发式**(无搜索树,单步决策毫秒级),分四块:

### 5.1 记牌基础设施

| 函数 | 回答的问题 |
|------|------------|
| seenCards | 到目前为止桌面上亮过哪些牌 |
| unseenHigher / unseenHigherPair | 这张牌/这个对子在组内是否已是当前最大(boss),对手还可能有几张更大的 |
| othersTrumps | 对手手里约还剩多少主(主牌全集 42 张减去已见与自持;底牌不可见,宁可高估) |
| voidGroups | 从墩历史推断谁在哪门已断门(没跟上首攻组) |
| ruffRisk | 我在某边花色的赢牌会不会被"断门且没断主"的对头用主砸掉 |
| provenFollows | 某人是否曾整手跟上过某门(证实他有这门牌) |

### 5.2 喊分 / 亮主 / 扣底

- 喊分:按"坐庄实力"给手牌打分(王 ×1.6 + 3 ×1.3 + 2 ×1.0 + 最长花色 ×0.5 + 对子 ×0.3 + 短门 ×0.8),映射到目标价;实力大幅超过当前价时跳喊 +20 施压。
- 亮主:选最长花色。
- 扣底:优先把短且无大牌的边花色整门扣掉做空门;5/10 打不赢就藏进底牌护分(闲家抢不到),A/K 留着打。

### 5.3 出牌

首攻决策链(依序尝试,先命中先出):

1. **拖拉机**(3 连对直接出,2 连对需顶对必大)
2. **庄家控主**(boss 主对优先——必赢且"跟大"规则会逼对手交出最大的单主;其次 boss 单张;都没有但主够长则便宜快拉;对手全部亮出断主立即停)
3. **boss 对子**
4. **甩牌**(只甩"落单"的必大主,绝不拆对子)
5. **boss 单张**(避开会被砸的花色)
6. **借刀杀人**(闲家专属:队友断门且有主、庄家没断且紧跟我后手时,甩分牌让队友用主杀,分归闲家)
7. **小牌过渡**(不送分、不拆对)

跟牌:能吃住当前最大时,庄家抢闲家的分墩、闲家只抢庄家的墩(有分或最后一手才抢;另有"白捡"——用反正最大的单张零成本抢回首攻权);不抢则智能垫牌——队友稳赢就喂分(优先大分牌),对手可能赢就躲分(分牌押后)。"队友稳赢"包含提前喂分:队友领出的边花色必大且庄家被证实还有这门时,不等庄出牌就喂。

### 5.4 A/B 对战台(改 AI 必用)

ai.go 顶部有实验开关 `aiV4Zhuang / aiV4Xian`(按角色生效,正式行为全 true);`ab_test.go` 让新旧策略按角色互打,量化改动净收益:

```bash
go test ./server/game/ -run TestAB3P -v
# 输出四组各 2000 局:基线 / 只升级庄家 / 只升级闲家 / 全升级 的庄家胜率与闲家场均捡分
```

> **为什么必须用它**:有过真实教训——"庄家用小对子拉主榨跟大"直觉上很妙,实测庄家胜率从 62.3% 跌到 59.5%;"只用必赢结构拉主"更是跌到 50.5%;最终数据选出的方案(boss 对优先 + 便宜快拉保留)升到 66.7%。直觉在牌桌上经常是错的,改 AI 一律先跑对战台再定稿,然后同步 Swift/JS。

## 6. 测试

```bash
go test ./...                                # 全量:规则用例 + 模拟 + 服务器协议测试
go test ./server/game/ -run TestSim -v       # 3/4 人各 300 局:AI 合法性 + 结算守恒 + 胜率
go test ./server/game/ -run TestAB3P -v      # AI 策略 A/B 对战
```

## 7. 运行与部署

```bash
# 本地开发(-root . 直读仓库文件,改前端刷新即生效;日志会打印局域网地址供手机直连)
go run ./server -root .          # 默认 :8124,或被 PORT 环境变量覆盖

# 生产:单二进制(前端已内嵌,不需要 -root)
go build -ldflags='-s -w' -o biaofen ./server && ./biaofen

# 云端:Render 一键 Blueprint(读 render.yaml / Dockerfile),得到 https://xxx.onrender.com
```

客户端连接地址即部署域名(iOS/Web 会自动补 wss:// 与 /ws 路径)。注意公司办公网常开"客户端隔离",设备互 ping 不通,局域网联机测试建议用手机热点或直接走云端部署。

## 8. 常见维护任务怎么做

| 任务 | 做法 |
|------|------|
| 改规则 | 改 game/ 对应文件 + 补测试用例,go test 全绿;按总览铁律同步 Swift/JS;若涉及下发字段还要改 view.go 与两端客户端 DTO |
| 改 AI | ai.go 加逻辑(可挂实验开关),TestAB3P 验证胜率,再同步两端 |
| 加协议消息 | client.go 的 ClientMsg 加字段 → room.go handleMsg 加分支 → 客户端上行;下发则改 view.go/emit |
| 排查"对局卡住" | 看日志 + room.go 的 pendingSeat/scheduleBots:十有八九是轮到某座位但既非在线真人又没排 AI 定时器;botSeq 作废逻辑是第二嫌疑 |
| 排查"出牌不合法" | 与 Web 端一致:对照 follow.go 的 isLegalFollow 逐条件核对;先用 go test 写个最小重现用例 |
