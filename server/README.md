# 今夜星 天气代理服务

阿里云 ECS 上的 Node 服务，作用有三：

1. **藏 Key** —— 和风 API Key 只存在服务端 `/etc/nightwindow-api.env`，客户端拿不到
2. **共享缓存** —— 上游按 0.5° 取整去重，30 分钟 TTL，所有用户共享
3. **少请求** —— 地图网格一次拿回 7×7 = 49 个点，不再逐点打上游

## 接口

| 路径 | 说明 |
|---|---|
| `GET /healthz` | 存活检查 |
| `GET /v1/wx?lat&lon` | 单点 24 小时预报 |
| `GET /v1/grid?lat&lon&span&n` | 网格预报（`span` = **总跨度**公里，`n` ≤ 9）|

单 IP 每小时 120 次（`X-Forwarded-For` 由 nginx 注入）。

## 返回格式

```json
{
  "ok": true, "okPoints": 49, "total": 49, "span": 150, "n": 7,
  "points": [
    { "lat": 30.1, "lon": 103.8,
      "hours": [ { "t": "2026-11-09T20:00+08:00", "c": 100, "ws": 14, "wd": 0,
                   "h": 62, "p": 0, "pr": 975, "tp": 13, "dw": 6 } ] }
  ]
}
```

`c` 云量 %、`ws` 风速 km/h、`wd` 风向、`h` 湿度 %、`p` 降水 mm、`pr` 气压、`tp` 气温、`dw` 露点。

## 部署（阿里云 ECS）

```bash
# 1. 代码
ssh / workbench → mkdir -p /opt/nightwindow-api
# 上传 server.js 到 /opt/nightwindow-api/server.js

# 2. 环境变量（含 Key，权限 600）
cat > /etc/nightwindow-api.env <<'ENV'
NW_PORT=8090
QW_HOST=mn6hf38tay.re.qweatherapi.com
QW_KEY=<和风 Key>
ENV
chmod 600 /etc/nightwindow-api.env

# 3. systemd
cp nightwindow-api.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now nightwindow-api

# 4. nginx（skyinstrument.cn 的 443 server 块内）
#    location ^~ /nw/ { proxy_pass http://127.0.0.1:8090/; }
nginx -t -c /etc/skyinstrument-website/nginx.conf && \
  nginx -s reload -c /etc/skyinstrument-website/nginx.conf
```

## 注意

`span` 是**总跨度**，不是步长：步长 = `span / (n - 1)`。
早期版本按步长实现，实际采样范围是请求值的 6 倍，导致地图色场偏移、放大后大量点落在海面/境外而「取数失败」。

和风对海面与境外坐标返回 **400**，这类点会进 10 分钟负缓存，不再重复请求。

## 缓存

两层：内存 + 磁盘。重启不冷启动。

| 项 | 值 |
|---|---|
| 键 | 0.5° 取整坐标（≈55km 合并）|
| TTL | 30 分钟（`NW_TTL_MS` 可覆盖）|
| 上限 | 800 条，超出按插入顺序淘汰 |
| 落盘 | `/var/lib/nightwindow/wx-cache.json`（`NW_CACHE_FILE` 可覆盖）|
| 落盘时机 | 上游返回后 15 秒合并写一次；SIGTERM 时立即刷盘 |
| 写入方式 | 先写 `.tmp` 再 `rename`，进程被杀也不会留半个文件 |
| 负缓存 | 400/204/404 的坐标记 10 分钟，不再重试 |

systemd 用 `StateDirectory=nightwindow` 自动创建 `/var/lib/nightwindow`，
并在 `ReadWritePaths` 里放行（服务开了 `ProtectSystem=strict`，不加会写失败）。

## 配额

- 单点：每个 0.5° 格子 30 分钟一次
- 网格：49 个点去重后通常 16–25 次上游
- 和风免费额度 1000 次/天，全体用户共享同一份缓存

## 本地开发

```bash
QW_KEY=xxx NW_PORT=8090 node server.js
curl "http://127.0.0.1:8090/v1/grid?lat=30.67&lon=104.06&span=150&n=5"
```
