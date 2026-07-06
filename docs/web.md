# 飙分 Web 端技术设计

> 总览、规则、三端共通概念见 [README.md](README.md),读本文前请先读它的第 5 节。

## 1. 技术选型

**原生 JavaScript(ES Modules)+ 原生 DOM,零框架、零构建依赖、零 npm 包。**选择理由:逻辑体量小(全部源码约 3000 行)、需要"双击 HTML 就能玩"的零部署分发形态。这意味着维护时不需要 node_modules、不需要 webpack,浏览器打开就是所见即所得;唯一的"构建"是把多文件拼成单文件(见第 5 节)。

## 2. 文件与模块分层

| 文件 | 层 | 职责 |
|------|----|------|
| `src/cards.js` | 引擎 | 牌与牌堆:makeCard/buildDeck、常主判定 isTrump、分组 cardGroup、两套刻度 strength/tractorRank、洗发牌、手牌排序 sortHand(边花色按"手里实际存在的花色"黑红交错) |
| `src/combos.js` | 引擎 | 牌型:detectCombo(单/对/拖拉机,主 A 两个取位都试)、beats 压制判断、resolveTrick 收墩 |
| `src/follow.js` | 引擎 | 跟牌合法性 isLegalFollow(出满该组、结构优先、主牌跟大)、pairCount、maxTractorLen |
| `src/game.js` | 引擎 | 一局的状态机 Game 类:喊分→亮主→扣底→出牌→结算;validatePlay / validThrow(甩牌)/ playCards / 翻底与结算公式 |
| `src/ai.js` | 引擎 | 电脑玩家:喊分评估与跳喊、亮主、扣底藏分、首攻决策链、跟牌抢/垫/喂,与 Go 版逐函数对齐(策略详解见 [server.md](server.md) 第 5 节,两边完全一致) |
| `src/sfx.js` | 界面 | WebAudio 程序合成音效(无音频素材文件):选牌/出牌/收墩/喊分/亮主/胜/负,localStorage 记住静音 |
| `src/ui.js` | 界面 | 单机版控制器:渲染 + 交互 + AI 驱动(本文核心,见第 3 节) |
| `src/online.js` | 界面 | 联机版客户端:WebSocket 连接、房间大厅、按服务器视图渲染(见第 4 节) |
| `index.html / mobile.html` | 入口 | 单机开发版(电脑/手机布局),ES modules 直接引 src/,改代码刷新即生效 |
| `online.html` | 入口 | 联机版入口,需要 Go 服务器托管(见 [server.md](server.md)) |
| `飙分-电脑版.html / 飙分-手机版.html` | 产物 | build.js 打包出的自包含单文件,可直接发给别人双击玩,**不要手改** |
| `css/style.css / css/mobile.css` | 样式 | 桌面/移动两套布局;卡面样式(.card/.idx/.big/.joker/.trump/.sel) |

依赖方向永远是单向的:`cards ← combos ← follow ← game ← ai ← ui/online`。引擎层(前五个文件)不碰 DOM、不碰音频,可以在 Node 里跑测试。

## 3. 单机版(ui.js)工作原理

### 3.1 状态

模块级几个变量就是全部状态:`g`(Game 实例)、`selected`(选中牌 id 的 Set)、`frozenTrick`(收墩后留在桌上展示的上一墩)、`aiTimer`(AI 出牌定时器)。人类固定坐 0 号位(常量 HUMAN)。

### 3.2 渲染循环

没有虚拟 DOM,就是"每次状态变化后整体重画":`render()` 依次调 renderStatus / renderOpponents / renderTrick / renderCaptured / renderHand / renderActions,各自 innerHTML 重建自己那块区域。牌面由 `cardEl(card)` 生成(左上角标 + 中央大花色,王牌有专属样式)。

### 3.3 流程驱动(tick)

`tick()` 是心跳:先 render,再看当前阶段轮到谁——轮到电脑就设一个 750ms 定时器执行 AI 动作后再 tick,轮到人类就停下等点击。人类的每个操作(喊分按钮、选牌、出牌)最终都调回 tick()。这样"谁来推进游戏"永远只有一个入口,不会出现并发错乱。

### 3.4 收墩定格

一墩打完后 `frozenTrick` 记住整墩(renderTrick 优先画它,带赢家标记),1.4 秒后恢复 AI 节奏;但定格牌**保留到下一圈有人出牌**(doPlay 开头清 frozenTrick),让玩家看清上一墩。最后一墩结束进结算弹窗,弹窗里翻开底牌。

### 3.5 交互细节

- 喊分:快捷按钮(当前档 +0/+10/+20)+ 下拉直达任意更高档(引擎本来就允许跳喊)。
- 扣底:亮主后底牌自动全选(方便看清哪些是底牌),数量凑齐才能确认。
- 出牌:选牌即时用 `g.validatePlay()` 预校验,按钮态和提示文案(牌型名/甩牌/不合法原因)实时更新。

## 4. 联机版(online.js)工作原理

联机时**浏览器里没有 Game 实例**,只有服务器下发的视图对象 `S`(见 [server.md](server.md) 第 4 节的字段表)。online.js 做三件事:

1. **连接与房间**:WebSocket 连 `/ws`;第一条消息 create(建房)或 join(房间码入房);收到 joined 后记住自己的 seat 和 token(token 用于断线重连回原座位)。
2. **渲染**:每收到一条 state 就整体重画(与单机同一套牌面组件思路);收墩定格逻辑与单机一致(tricksPlayed 增加且新墩为空时 frozenTrick=lastTrick,下一圈出牌的 state 到达时清掉)。
3. **操作上行**:所有动作都只发消息(bid/trump/bury/play/next,牌用 id 列表),合法性由服务器裁决,非法会收到 error 提示。

## 5. 打包(build.js)

产出"零依赖单文件 HTML"的原理很朴素:按依赖顺序读入 `src/cards.js … sfx.js`,正则去掉 import/export 行(所有定义共享一个作用域),ui.js 里的 `AI.xxx` 命名空间还原成裸函数名,连同 css 一起内嵌进 HTML 模板,分别写出电脑版/手机版。

> **改了 `src/` 或 `css/` 之后必须重新跑 `node build.js`**,否则两个单文件版还是旧的。两个"飙分-*.html"是生成产物,不要手改。

## 6. 测试与日常命令

```bash
npm test            # 规则用例:test/engine.test.js + test/follow.test.js(53 项)
node test/sim.js    # 全 AI 自动对局 200 局:合法性 + 结算守恒 + 胜率统计
node build.js       # 重新打包单文件版
npm run online      # = go run ./server -root . ,本地起联机服务器并托管前端
```

## 7. 常见维护任务怎么做

| 任务 | 改哪里 |
|------|--------|
| 改界面文案/布局 | ui.js(单机)或 online.js(联机)+ css;跑 build.js |
| 加一个音效 | sfx.js 里加合成函数并在 ui.js 对应事件处调用;注意 build.js 的文件列表已包含 sfx.js |
| 改规则/牌型 | 先改 Go(server/game/),再同步 src/ 对应文件,跑 npm test + node test/sim.js;iOS 也要同步(见总览铁律) |
| 改 AI | 同上,且先在 Go 的 A/B 对战台验证(见 [server.md](server.md) 第 5.4 节),src/ai.js 与 ai.go 逐函数对齐照抄即可 |
| 排查"出牌不合法" | 断点打在 follow.js 的 isLegalFollow,对照 [README.md](README.md) 5.4 节的规则逐条件看哪条不满足 |
