// main.go — 「飙分」联机服务器:静态文件 + /ws WebSocket
// 本地开发(仓库根目录):go run ./server -root .   → http://localhost:8124/online.html
// 部署:go build -o biaofen ./server → 单二进制(前端已内嵌),./biaofen 即可
package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/gorilla/websocket"

	assets "biaofen"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// 局域网/手机直连 IP 访问,不校验 Origin(身份靠房间 token,不用 Cookie)
	CheckOrigin: func(r *http.Request) bool { return true },
}

func newMux(hub *Hub, static http.FileSystem) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, req *http.Request) {
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			log.Printf("upgrade: %v", err)
			return
		}
		c := &Client{hub: hub, conn: conn, send: make(chan []byte, 256)}
		go c.writePump()
		go c.readPump()
	})
	mux.Handle("/", http.FileServer(static))
	return mux
}

// 监听地址:-addr 优先;云平台(Render/Zeabur 等)注入 PORT 环境变量时自动采用
func defaultAddr() string {
	if p := os.Getenv("PORT"); p != "" {
		return ":" + p
	}
	return ":8124"
}

func main() {
	addr := flag.String("addr", defaultAddr(), "监听地址")
	root := flag.String("root", "", "静态文件根目录;留空 = 使用编译时内嵌的前端(部署),本地开发传仓库根以便热改前端")
	flag.Parse()

	var static http.FileSystem
	if *root != "" {
		static = http.Dir(*root)
	} else {
		static = http.FS(assets.FS)
	}

	mux := newMux(NewHub(), static)

	log.Printf("飙分联机服务器启动: http://localhost%s/online.html", *addr)
	for _, ip := range lanIPs() {
		log.Printf("  局域网(手机同 WiFi 可开): http://%s%s/online.html", ip, *addr)
	}
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func lanIPs() []string {
	var out []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() {
			if ip4 := ipn.IP.To4(); ip4 != nil {
				out = append(out, ip4.String())
			}
		}
	}
	return out
}
