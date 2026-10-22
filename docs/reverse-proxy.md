# 反向代理接入 dsh Web UI

面向「nginx / Caddy / frp 等反代 + 域名 + HTTPS」的接入手册。dsh 侧的权威口径是官方
[在反向代理之后发布 Web UI](https://deepseek-harness.github.io/deepseek-harness/guide/public-deployments)；
本文补充 dshctl 侧的参数、实测现象与可直接套用的 nginx 配置。

## 1. 先分清三件事

| 机制 | 由谁负责 | 作用 | 不做什么 |
|---|---|---|---|
| **启动 token** | dsh | 首次访问的**唯一认证**入口 | 不是「反代参数」，无法用反代关掉 |
| **会话 cookie** | dsh | token 交换后签发的签名凭证，**绑定访问用的 authority** | 不绑定就无法防重放 |
| **Host 栅栏（/api 403）** | dsh（`--trusted-host`） | 放行浏览器可见 authority，防 DNS rebinding | **不认证**，只决定「是否继续处理」 |
| **反代自身认证** | 你的 nginx/Caddy | 额外一道门（basic auth 等） | 与 dsh token 完全独立，两者都要过 |

关键推论：**反代配置正确时，首次访问仍然必须带 token**；不带就一定是
`dsh web authentication required; reopen the URL printed by dsh web.`，这不是故障。

## 2. 反代必须满足的硬性要求

1. **保留浏览器可见的 `Host`。** dsh 用「收到的 Host」作为 cookie 作用域（authority），
   并且用它和 `--trusted-host` 比对。反代把 Host 改写成 `127.0.0.1:3080` 或后端 frp 地址，
   会同时造成 **cookie 名字对不上（每次访问都要求重新认证）** 和 **`/api` 403**。
2. **转发 WebSocket 升级头**（`Upgrade` / `Connection`）。否则页面能打开，但会话消息、
   工具输出、流式响应不推送，前端一直重连。
3. **若带挂载前缀**（如 `https://host/ui/`），必须把前缀剥掉再转发，并重定向裸挂载：
   `/ui` → `/ui/`。`--public-url` 只是「公告」，不会让 dsh 认识挂载。
4. **`--trusted-host` 点名浏览器实际使用的 authority**（可带端口；不带端口匹配任意端口）。
   `--public-url` 不授予信任。
5. **不要添加 CSP 响应头。** dsh 前端需要无 nonce 的内联引导脚本、动态代码生成
   （配置页的 `!!js` 表达式求值）与内联 `data:` 字体；要同时满足，`script-src` 就得
   放开 `'unsafe-inline'` 与 `'unsafe-eval'` —— 此时 CSP 对 XSS 的防护已归零，
   却仍在实打实地打断功能。**移除，而不是修补**，理由见第 4 节。
6. **若反代自身启用 basic auth**：`auth_basic` 会作用于**所有路径**，包括本应免鉴权的静态
   资源（控制台出现 `/manifest.webmanifest` 的 401 噪音），后端故障时错误页也会变成登录框。
   两者的放行写法见第 3 节模板。
7. **多层转发（frp / 隧道）时，Host 只在最靠近浏览器的那层决定。** 典型链路是
   `浏览器 → 宿主机 nginx → frps → frpc → dsh`。nginx 设好 `proxy_set_header Host $host`
   之后，**隧道段不得再改写 Host**，否则第 1 条的效果被后一层抵消，前功尽弃。
   自查方法：确认 dsh 收到的 Host 就是浏览器地址栏里的域名。
8. **长连接由 dsh 自己按心跳切断，反代拦不住，只能减少触发。** Gateway 每 2 秒向
   WebSocket 发一次 Ping，连续 2 个周期（约 **4 秒**）收不到任何活动就主动 `terminate()`。
   这是**服务端**行为：`proxy_read_timeout` 配多长都不改变它，反代多出的一跳只会让
   Ping/Pong 更容易迟到。所以两项都要做：
   - 反代侧把 WebSocket 与 SSE **单独分流**，并开启上游 TCP 保活（第 3 节模板）；
   - 公网或高抖动链路调大 dsh 侧 `websocketHeartbeatIntervalMs`（第 9 节）。

## 3. nginx 模板

以下为完整可用配置，含 basic auth 放行、WebSocket / SSE 分流、上游保活与后端故障页处理。

先在 `http` 块内准备 WebSocket 升级映射：

```nginx
# /etc/nginx/nginx.conf — http 块内
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

把代理参数抽成 snippet，供多个 location 复用：

```nginx
# /etc/nginx/snippets/dsh-proxy.conf
proxy_pass http://127.0.0.1:3080;

proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $connection_upgrade;

# 必须是 $host：写成 127.0.0.1:3080 / $proxy_host 会让 cookie 作用域与 /api 栅栏同时失效
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
# 仅用于代理自身日志与规则；dsh 不据此判定 cookie 是否加 Secure（见第 8 节）
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Port  $server_port;

proxy_connect_timeout 60s;
proxy_send_timeout    3600s;
proxy_read_timeout    3600s;

# 上游 TCP 保活（nginx >= 1.15.6）：空闲长连接不被中间设备悄悄回收
proxy_socket_keepalive on;

# 流式响应不被缓冲
proxy_buffering off;

proxy_intercept_errors on;
error_page 502 503 504 /50x.html;
```

站点配置：

```nginx
# /etc/nginx/sites-available/dsh.example.com
server {
    listen 80;
    listen [::]:80;
    server_name dsh.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

    include snippets/ssl-params.conf;
    include snippets/security-headers.conf;   # 见第 4 节：此文件内不要有 CSP

    client_max_body_size 500m;

    # dsh token 之外的第二道门。强烈建议保留，理由见第 7 节
    auth_basic "restricted";
    auth_basic_user_file /etc/nginx/.dsh-htpasswd;

    # ① 免鉴权静态资源：dsh 只对 / 与 /index.html 校验凭证，这个文件本就无需认证。
    #    server 级 auth_basic 会连它一起拦下 → 控制台 401 噪音。放行它无风险。
    location = /manifest.webmanifest {
        auth_basic off;
        include snippets/dsh-proxy.conf;
    }

    # ② WebSocket 主连接：会话消息、工具输出、流式响应的唯一通道。
    #    单独列出，避免将来给普通 location 加规则时误伤长连接。
    location = /api/remote.mux {
        include snippets/dsh-proxy.conf;
    }

    # ③ SSE 事件流：client plugin 推流端点。
    #    gzip 会缓冲 SSE 帧，导致事件延迟甚至攒到最后一起发出，必须关掉。
    location = /plugins/events {
        gzip off;
        include snippets/dsh-proxy.conf;
    }

    location / {
        include snippets/dsh-proxy.conf;
    }

    # ④ 扫描器与敏感路径：直接断开连接，不返回任何内容
    location ~* (\.env|\.git|\.DS_Store|/console|/server-status|/actuator|/trace\.axd|/HNAP1) {
        return 444;
    }

    # ⑤ 后端故障时的友好页：少了 auth_basic off，用户看到的是登录框而不是这里
    location = /50x.html {
        root /var/www/html;
        internal;
        auth_basic off;
    }
}
```

## 4. 如果确实要保留 CSP

### 4.1 先看 nginx 的 `add_header` 语义

这一段决定了你**能不能**在站点里「覆盖」那条 CSP：

- **追加，而非覆盖。** 同一配置层内出现多条同名 `add_header`，响应里就是**多个同名响应头
  并存**。浏览器对多个 CSP 按**交集**执行。
  ⇒ 在 vhost 里再写一条 `Content-Security-Policy` **不会替换** `include` 进来的那条，
  而是两条同时下发，**坏的那条照样生效**。要改 CSP，只能改**源头那个被 include 的文件**。
- **继承会被整段打断。** nginx 的 `add_header` 只在「当前层没有任何 `add_header`」时才继承
  上层。只要在某个 `location` 里写了**任意一条** `add_header`（哪怕加的是 `X-Robots-Tag`），
  该 location 会**丢弃**从 `server` / `http` 继承来的**全部** `add_header` ——
  **HSTS 会静默消失**。
  ⇒ 安全头统一在 `server` 级 `include` 时，就不要再往 `location` 里加 `add_header`；
  确实要加，就把该 location 需要的头**全部重述一遍**。

### 4.2 dsh 前端的三个硬需求

| 需求 | 依据 | 需要放开的指令 |
|---|---|---|
| **内联引导脚本，且不带 nonce** | 反代注入 `globalThis["__DSH_BOOT__"] = {…}` | `script-src 'unsafe-inline'` |
| **动态代码生成** | 配置页的 `!!js` 表达式求值器（`new Function` + `eval`） | `script-src 'unsafe-eval'` |
| **内联字体** | 前端 CSS 内嵌 `data:font/woff2;base64,…` | `font-src 'self' data:` |

### 4.3 最小可用的 CSP

```nginx
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'" always;
```

### 4.4 结论

`'unsafe-inline'` 与 `'unsafe-eval'` **必须同时放开**，而这两个恰恰是 CSP 防 XSS 的主要
价值所在。两者齐放之后，CSP 剩下的能力基本只有「误伤功能」。

- **优先直接移除**：dsh Web UI 本身就是「可执行命令的界面」，把它暴露到公网时，CSP 带来的
  边际收益有限，而配置不当造成「界面看着能开、功能悄悄坏掉」的概率更高。
- 若因合规等原因必须保留，请接受它只是声明式摆设，并按 4.1 的方式**改源头文件**。
- 不要在 CSP 里保留 `https://cdn.jsdelivr.net` 之类的外部脚本源。对这类应用，
  放行第三方脚本等于把执行权交给该 CDN。

## 5. 验证清单

```bash
# ① 首次访问必须带 token（正确行为：303 + Set-Cookie，然后 302 到 ./）
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: dsh.example.com' \
  "http://127.0.0.1:3080/?token=<从 dshctl --url 或启动输出取>"

# ② Host 栅栏状态：401 = 栅栏放行（只差 token/cookie）；403 = 该 Host 未被信任
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: dsh.example.com' http://127.0.0.1:3080/api/

# ③ 免鉴权静态资源应为 200（若公网返回 nginx 的 Basic 401 页，说明被反代认证拦下）
curl -s -o /dev/null -w '%{http_code}\n' https://dsh.example.com/manifest.webmanifest

# ④ WebSocket 升级是否被转发：浏览器 DevTools → 网络 → WS 标签
#    正常应为 101 Switching Protocols；若反复 pending/断开，说明 Upgrade 头没被转发

# ⑤ 安全头是否按预期下发（改过 include 或 add_header 后务必复查）
curl -sI https://dsh.example.com/ | grep -iE 'strict-transport|content-security-policy'

# ⑥ 后端故障页（可选）：停掉 dsh 后访问域名，应看到 /50x.html 而不是 basic auth 登录框

# ⑦ 长连接是否稳定：DevTools → 网络 → WS → 选中 /api/remote.mux
#    - 每 4 秒左右断开一次、关闭码 1006 → 心跳窗口不够，见第 9 节
#    - 稳定 101 且不主动关闭 → 正常
```

浏览器控制台对照：

| 现象 | 归属 | 处理 |
|---|---|---|
| `dsh web authentication required` | dsh | 用带 token 的完整地址首次访问（`dshctl --url`） |
| `/api` 403 | dsh Host 栅栏 | `--trusted-host` 点名该 authority 并重跑 `--install` |
| `manifest.webmanifest` 401 | 反代自身的 basic auth | 见模板里的 `location = /manifest.webmanifest` |
| `Refused to load the font 'data:font/...'` | 反代的 CSP | 移除 CSP 或补 `font-src 'self' data:` |
| `EvalError: ... 'unsafe-eval' is not an allowed source` | 反代的 CSP | 移除 CSP 或补 `'unsafe-eval'` |
| `preload ... not used within a few seconds` | 浏览器提示 | 无需处理（只影响加载优先级） |
| **配置页保存失败 / `HTTP 403`**（特定插件） | **插件自身的「写请求须来自回环」策略** | 改用 `http://localhost:<port>/` 打开界面操作，或按插件文档放行管理主机；**与反代配置无关** |

## 6. 与 dshctl 参数的分工

```bash
bash dshctl.sh --install --force-update --rebuild \
  --public-url https://dsh.example.com \
  --trusted-host dsh.example.com
```

- 以上三项随 `--install` 写入 `~/.local/bin/dsh` 启动器，`--start` 时也会临时生效；
- `--public-url` 决定启动输出、`DSH_WEB_URL` 与 `dshctl --url` 展示的地址；
- `--trusted-host` 决定 `/api` 栅栏放行哪些 authority（**少了它 = 全部 403**）；
- 两者都**不能**替代首次访问的 token，也**不能**修复反代改写 Host 造成的 cookie 失效。

## 7. dsh 自己不设防的路径

在反代层做认证之前，先了解 dsh 自身鉴权的覆盖面 —— **它并不覆盖全部路径**。
下表为不带任何凭证直接请求 dsh 监听端口（Host 为回环地址）的实测结果：

| 路径 | 无凭证 | 说明 |
|---|---|---|
| `/`、`/index.html` | 401 | 启动 token 认证门 |
| `/api`（含全部子路径） | 401 | RPC 主体 |
| `/api/remote.mux`（WebSocket） | 401 | **命令执行通道**，已受保护 |
| `/connect` | 401 | token 换 cookie 的入口 |
| `/open-in-app/apps`、`/open-in-app/open` | 401 | |
| `/assets/*` | 200 | 前端构建产物 |
| `/manifest.webmanifest` | 200 | PWA 清单 |
| **`/plugins/events`** | **200** | **SSE：完整插件清单、依赖图、bundle URL 与版本号** |
| **`/plugins/<bundle>`** | **200** | **插件源码**（实测单个 bundle 约 84 KB） |

机制：静态资源服务只对 `/` 与 `/index.html` 校验凭证，其余路径直接读文件；
`/plugins/*` 属于开发期热重载（HMR）端点，其 handler 只校验 HTTP 方法，不校验凭证。

**这决定了反代认证不是可选项：**

- 暴露插件清单与第三方插件源码属于**信息泄露**（版本指纹、内部依赖、私有插件实现）；
- 命令执行通道（`/api/remote.mux`）**已被 dsh 正确保护**，所以这**不是**「能直接拿下你的机器」；
- 但 `/plugins/*` 是 dsh 自身**没有设防**的部分 —— **反代上的认证层往往就是唯一覆盖它的那一层**。
  既然已经用反代暴露，就**不要省掉反代认证**。

## 8. token 与 cookie 的生命周期

| 项 | 行为 | 运维含义 |
|---|---|---|
| **启动 token** | 每次 dsh 启动**重新生成** | 旧的 `?token=` 链接在重启后失效；用 `dshctl --url` 取当前有效的 |
| **会话 cookie** | 由 token 在 `/connect` 换取，签发后**默认 30 天**有效 | **dsh 重启后浏览器无需重新带 token** —— cookie 仍然有效 |
| **cookie 名称** | 由 `sha256(authority)` 派生 | **绑定访问用的域名与端口**。换域名、换端口 → 旧 cookie 立即失效，需重新走 token |
| **cookie 的 `Secure` 标志** | **不加**。dsh 只依据自身监听器的协议判断，**不读 `X-Forwarded-Proto`** | 反代终结 TLS 时 cookie 会缺少 `Secure` ⇒ **必须由反代下发 HSTS 作为补偿** |

⚠️ **token 会进反代的访问日志。** 首次访问的请求行是 `GET /?token=…`，而常见的
`log_format` 会记录 `"$request"`（**包含查询串**），于是明文 token 落盘。若日志会被轮转、
外发或共享，请剥掉查询串：

```nginx
# http 块内：访问日志中隐藏 token 查询串
map $request_uri $loggable_uri {
    default           $request_uri;
    "~^/\?token="     /;              # 根路径带 token 的请求，只记 /
}

# 然后把 log_format 里的 "$request" 换成 "$request_method $loggable_uri $server_protocol"
```

## 9. 调大 WebSocket 心跳窗口

dsh 的 Gateway 默认每 **2 秒**发一次 WebSocket Ping；一个 socket 连续 **2 个周期**
（约 4 秒）没有任何活动（Pong、收到的帧、或完成的下行写入）就会被 `terminate()`。
浏览器随后按退避策略自动重连 —— 用户看到的是「用一会儿就断、过几秒又连上」。

这**不是反代配置错误**。`proxy_read_timeout` 配成 3600s 也不会改变它，因为判定发生在
dsh 进程内；反代（尤其是跨境链路）只是让 Ping/Pong 更容易迟到。

### 9.1 用 dshctl 调整（推荐）

```bash
dshctl --gateway-heartbeat          # 查看当前值与容忍窗口（只读）
dshctl --gateway-heartbeat-set 30000 -y
dshctl --restart                    # 该参数在启动时读取，重启生效
dshctl --gateway-heartbeat          # 复核
```

想看当前值又不想重启：

```bash
dshctl --gateway-heartbeat
```

输出会同时给出「容忍停顿」，即 `2 × 心跳间隔`，省去自己换算：

```
  心跳间隔     : 30000 ms（30 秒）[已显式设置]
  容忍停顿     : 60000 ms（60 秒）= 2 × 心跳间隔
```

改回 dsh 默认（2000 ms / 4 秒窗口）：

```bash
dshctl --gateway-heartbeat-reset -y && dshctl --restart
```

命令写入的是 `~/.dsh/profiles/<profile>/cordis.patch.yml` 里 `typert-gateway`
的 `config.websocketHeartbeatIntervalMs`，**只增删这一行**：同一 `config` 下的
其他键（例如 `streamInboxBytes`）与文件其余内容原样保留，改动前自动备份
（`cordis.patch.yml.bak.<时间戳>`，保留最近 3 份）。

<details>
<summary>手工编辑方式（不用命令时）</summary>

编辑 `~/.dsh/profiles/<profile>/cordis.patch.yml`（默认 profile 是 `web`）：

```yaml
- id: typert-gateway
  name: "@deepseek-ai/dsh-api-gateway"
  config:
    websocketHeartbeatIntervalMs: 30000
```

⚠️ 这是 **config override**（dsh 在 profile 文件头部就是这么描述该层语义的）。
当前 bundle 里 `typert-gateway` 没有其他 config 项，所以只写这一条是安全的；
若你已在该条目里配了别的键，要一并保留，否则会被这条覆盖掉。用
`--gateway-heartbeat-set` 则无需操心这点。

</details>

### 9.2 取值参考

| 值（毫秒） | 容忍的无活动时长 | 适用场景 |
|---|---|---|
| **2000**（默认） | 约 4 秒 | 本机 / 低延迟内网 |
| 15000 | 约 30 秒 | 普通公网直连 |
| **30000** | 约 60 秒 | **反代 + 跨境链路推荐起点** |
| 60000 | 约 2 分钟 | 高抖动链路（移动网络、卫星） |

- 取值必须是**整数毫秒**，范围 1 ~ 2147483647；
- 不建议超过 120000：连接真的失效后要过更久才被发现，期间用户操作会静默丢失；
- 调大同时会降低 Ping 频率，空闲长连接的保活流量变少 —— 所以**不要指望它替代**
  `proxy_socket_keepalive`，两者解决的是不同环节。

### 9.3 各类断连现象的责任分工

| 现象 | 责任方 | 调哪里 |
|---|---|---|
| 约 4 秒断开一次，关闭码 **1006** | dsh Gateway | `websocketHeartbeatIntervalMs`（本节） |
| 空闲一段时间后被中间设备回收 | 反代 / NAT | `proxy_socket_keepalive` + 心跳周期 |
| 页面能开但消息不推送 | 反代 | `Upgrade` / `Connection` 头（第 2 节第 2 条） |
| `/api` 返回 403 | dsh Host 栅栏 | `--trusted-host` |
| 首次访问要求 token | dsh 认证门 | `dshctl --url` |
