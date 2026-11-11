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
| `GET /v1/grid?lat&lon&span&n` | 网格预报（`span` = **总跨度**公里）|
| `GET /v1/world` | 内置世界城市和观测点的 24 小时预报 |
| `GET /v1/week?lat&lon` | 单点 168 小时预报 |

坐标必须显式提供：`lat` 在 −85～85，`lon` 在 −180～180，零值合法。
`span` 默认 150，范围 100～5000；`n` 默认 7，必须是 3～9 的整数。
仅省略参数时使用默认值；空白、重复参数、NaN/Infinity、越界值均返回
HTTP 400 `{ "ok": false, "error": "bad ..." }`，不再静默钳制。
生成网格中超出支持坐标范围的点保留位置和点数，但 `hours`、`age` 为 null，不请求上游。

单 IP 每小时 120 次。IP 表最多 4096 项，满时拒绝新 IP（429），
不会通过淘汰尚有效的计数重置配额；记录一小时后过期。健康检查不计入限流。

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

## 代理信任契约

默认不信任任何 `X-Forwarded-For`，按 TCP 对端 IP 限流。
只有配置 `NW_TRUSTED_PROXY=127.0.0.1`（或 `::1`）且连接确实来自该地址，
才采用包含**单个有效 IP** 的 XFF；逗号链、无效值退回对端地址。
IPv6 和 IPv4-mapped IPv6 会规范化，避免同一地址用不同写法绕过计数。
配置非 loopback 地址会拒绝启动。服务仍只监听 `127.0.0.1`，当前部署应配置 IPv4 loopback。

nginx 必须覆盖用户传入的 XFF，不可使用 `$proxy_add_x_forwarded_for`：

```nginx
location ^~ /nw/ {
    proxy_pass http://127.0.0.1:8090/;
    proxy_set_header X-Forwarded-For $remote_addr;
}
```

本契约要求 nginx 直接接收公网连接；不得用不受信任的 real_ip 配置改写 `$remote_addr`。
若新增 CDN/负载均衡，需另行审查可信来源与地址提取规则。
loopback 信任无法区分 nginx 和同机其他进程；不要向不可信本机用户提供直连代理权限。
未开启该配置时，nginx 后全部用户共享 loopback 的 120 次额度，这是默认安全降级。

## 非 root 迁移步骤（仅说明，尚未部署）

1. 在服务器本地备份现有代码、unit、nginx 配置与缓存，记录实际运行用户及现有 drop-in；
   不输出或下载 `/etc/nightwindow-api.env` 内容。确认 Node.js 18+（内置 fetch）。
2. 创建专用系统用户/组 `nightwindow`，禁用登录、无 sudo、无额外组；先确认同名账户未被其他服务使用。
3. 将 **server.js 和 limits.js 一起**安装到 `/opt/nightwindow-api/`；代码由 root 持有，服务用户只读。
   保留现有 `/etc/nightwindow-api.env` 的 root:root 0600；系统级 systemd 读取 EnvironmentFile，
   无需为了非 root 服务扩大密钥文件读权限。环境变量仍由服务进程使用。
4. 停服迁移窗口内核对 `/var/lib/nightwindow` 及缓存不是符号链接、没有其他服务数据，
   确保目录及缓存归 `nightwindow:nightwindow`，目录 0700、文件 0600。
   `StateDirectory=nightwindow` 会创建并管理目录所有权，已有目录需先完成上述核查。
   自定义 `NW_CACHE_FILE` 必须放在该目录内，不要重新开放任意写路径。
5. 安装新 unit，检查旧 drop-in 没有覆盖 User、写路径或日志设置。
   新模板使用专用非 root 身份、空 capabilities、只读系统和私有临时目录；
   仅状态目录可持久写入，stdout/stderr 改走 journal，不再授权写整个 `/var/log`。
6. 先配置并验证 nginx 的覆盖 XFF 契约，再在环境配置中启用 `NW_TRUSTED_PROXY=127.0.0.1`。
   检查 nginx 配置及 `systemd-analyze verify` 后，再由维护任务执行 reload/restart。
7. 验证真实进程 UID、loopback 监听、健康接口、天气响应、缓存跨重启、伪造 XFF 无法改变公网身份；
   检查 `journalctl -u nightwindow-api` 及 journal 容量/留存。旧日志留存不自动删除。
   失败时回退配套代码和 unit/config，核对缓存所有权；回退可能恢复旧安全风险。

当前改动没有更新线上代码、unit、nginx、环境变量或账号。

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
| 上限 | 24 小时缓存 800 条、168 小时缓存 60 条；LRU，磁盘恢复也受上限约束 |
| 落盘 | `/var/lib/nightwindow/wx-cache.json`（`NW_CACHE_FILE` 可覆盖）|
| 落盘时机 | 上游返回后 15 秒合并写一次；SIGTERM 时立即刷盘 |
| 写入方式 | 先写 `.tmp` 再 `rename`，进程被杀也不会留半个文件 |
| 负缓存 | 24 小时接口 HTTP 400 / 业务码 204、404 记 10 分钟，最多 800 项，满时淘汰最早写入项 |

168 小时缓存 TTL 为 3 小时；该接口暂未增加负缓存。
systemd 用 `StateDirectory=nightwindow` 自动创建并开放 `/var/lib/nightwindow` 写入，
即使 `ProtectSystem=strict` 也无需额外宽泛的 `ReadWritePaths`。

## 并发和过载

24/168 小时上游请求共用每进程最多 **6 个运行 + 24 个等待**的调度器。
同一接口、同一 0.5° 坐标的运行中/等待中请求共享结果；两个接口的键隔离。
缓存命中不占队列，超出队列容量的未缓存点按既有失败契约返回：
单点 `ok:false`、网格/世界部分点 `hours:null`，week 为 `{ok:false,points:[]}`；不新增响应字段。
槽位覆盖响应体读取或取消，异常后释放，后续请求可重试；超时从实际开始回源起计算，
排队仍可能超过客户端读取超时。这里限制的是上游工作，不是客户端连接总数。

## 配额

- 单点：每个 0.5° 格子 30 分钟一次
- 网格：49 个点去重后通常 16–25 次上游
- 原部署记录的和风免费额度为 1000 次/天，需以实际账户套餐核实
- **尚无全局每日预算/费用硬限额**；6 并发不是每秒或每日配额。不同坐标、world/grid 扇出、
  失败重试仍可能耗尽额度。168 小时接口的授权及计费需要单独核实。
- IP 限流、缓存和调度器均按单进程工作，重启重置 IP 计数；多进程/多实例不共享额度。
  规模化前应增加持久预算、上游 429 退避、全局速率控制和入口连接/请求限制。

## 本地开发

```bash
QW_KEY=xxx NW_PORT=8090 node server.js
curl "http://127.0.0.1:8090/v1/grid?lat=30.67&lon=104.06&span=150&n=5"
```

从项目根目录运行 `node --test server/*.test.js`。仅使用 Node 内置测试框架；
HTTP 测试监听临时 loopback 端口，天气上游完全模拟，不读取真实密钥或访问上游服务。
