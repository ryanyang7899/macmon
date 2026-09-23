# macmon-server 多阶段构建 (x86/ARM 通用)
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
# 通配而不是逐个列名: 早先按名列举时新增 fan.go 没被复制进去,
# 本地编译通过、镜像里却缺文件, 直到构建才炸。
COPY *.go ./
COPY web/ ./web/
# 纯标准库, 无 CGO, 静态编译
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /macmon-server .

FROM alpine:3.20
RUN adduser -D -h /app macmon
WORKDIR /app
COPY --from=build /macmon-server .
# 预建数据目录并授权给 macmon 用户 (挂载命名卷时继承属主)
RUN mkdir -p /data && chown macmon:macmon /data
USER macmon
EXPOSE 8080
ENV DATA_DIR=/data
ENTRYPOINT ["/app/macmon-server"]
