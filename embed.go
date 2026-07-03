// embed.go — 把前端静态文件打进 Go 二进制(单文件部署,无需携带任何资源)。
// server/main.go 默认从这里取文件;传 -root 参数则改走磁盘(本地开发热改)。
package assets

import "embed"

//go:embed index.html mobile.html online.html css src
var FS embed.FS
