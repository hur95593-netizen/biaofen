// main.go — 「飙分」联机服务器:静态文件 + /ws WebSocket
// 运行(仓库根目录):go -C server run .   → http://localhost:8124/online.html
package main

import (
	"flag"
	"log"
	"net"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// 局域网/手机直连 IP 访问,不校验 Origin(身份靠房间 token,不用 Cookie)
	CheckOrigin: func(r *http.Request) bool { return true },
}

func newMux(hub *Hub, root string) *http.ServeMux {
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
	mux.Handle("/", http.FileServer(http.Dir(root)))
	return mux
}

func main() {
	addr := flag.String("addr", ":8124", "监听地址")
	root := flag.String("root", "..", "静态文件根目录(仓库根)")
	flag.Parse()

	mux := newMux(NewHub(), *root)

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
