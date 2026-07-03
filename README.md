# 飙分

一款由「二七王」改编的升级/拖拉机类扑克游戏(两副牌 108 张,常主 = 大小王、3、2)。
规则详见 [飙分-规则.md](飙分-规则.md)。

两种玩法:

- **单机版** — 纯前端,vs 电脑 AI(`index.html` 桌面 / `mobile.html` 手机)
- **联机版** — Go 后端多人实时在线:房间码开房、人不够电脑补位、掉线 AI 托管/重连接回(`online.html`)

## 本地运行

```bash
# 联机版(需要 Go 1.24+;-root . 表示前端走磁盘,改了 css/js 刷新即生效)
go run ./server -root .          # → http://localhost:8124/online.html
# 或 npm run online

# 单机版(任意静态服务器即可)
node server.js                   # → http://localhost:8123
```

联机服务器启动时会打印**局域网地址**,手机连同一 WiFi 打开即可一起玩。

## 测试

```bash
go test ./...                    # Go:规则引擎移植测试 + 600 局 AI 自动对局 + 联机集成测试
npm test                         # JS:前端引擎测试
node test/sim.js 600 3           # JS:AI 自动对局模拟
```

## 构建

前端已通过 `go:embed` 打进二进制,产物是**单个可执行文件**,不需要携带任何静态资源:

```bash
go build -ldflags="-s -w" -o biaofen ./server
./biaofen                        # 默认 :8124;云平台注入 PORT 环境变量时自动采用
```

## 部署

程序特点:WebSocket 长连接、房间状态在内存 → **只能单实例部署**(免费档/单机都天然满足)。
平台提供 HTTPS 时前端自动改用 `wss://`,无需配置。

### Render(免费,推荐)

1. 把仓库推到 GitHub
2. [render.com](https://render.com) → **New → Blueprint** → 选本仓库(会读取 `render.yaml`)→ Apply
3. 完成后访问 `https://<你的服务名>.onrender.com/online.html`

免费档说明:闲置 15 分钟休眠,下次访问约 1 分钟唤醒;**对局进行中有 WebSocket 消息,不会休眠**。
休眠会丢内存中的房间(房间本就是 10 分钟无人自动解散的临时设计,影响很小)。

### Zeabur(有香港区域,国内访问快)

[zeabur.com](https://zeabur.com) → 新建项目 → 从 GitHub 导入本仓库(自动识别 Dockerfile)→ 绑定域名。
免费档同样闲置休眠;要 24 小时在线可升 $5/月 档。

### 任意 VPS / 服务器

```bash
GOOS=linux GOARCH=amd64 go build -o biaofen ./server   # 交叉编译
scp biaofen 服务器:/opt/ && ssh 服务器 '/opt/biaofen'    # 上传即跑,无依赖
```

### Docker

```bash
docker build -t biaofen .
docker run -p 8124:8124 biaofen
```
