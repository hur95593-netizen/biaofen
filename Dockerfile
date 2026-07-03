# 多阶段构建:编译出内嵌前端的单二进制,塞进空镜像 → 最终镜像 ~10MB
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /biaofen ./server

FROM scratch
COPY --from=build /biaofen /biaofen
# 本地 docker run 用 8124;云平台(Render/Zeabur)注入 PORT 时程序自动改用
EXPOSE 8124
ENTRYPOINT ["/biaofen"]
