# macmon-server 多阶段构建 (x86/ARM 通用)
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
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
