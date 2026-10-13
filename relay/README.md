# LoLPing 1.5.0 服务器部署

服务器运行 WebSocket 房间中继，两台 Mac 使用 LoLPing 1.5.0 服务器联机版接入。原来的 LAN-only 客户端不能连接此服务。

## 已部署实例：IP 加密连接，服务端口 28787

当前部署位于 `18.236.249.217`，目录 `/opt/lolping/current`，Compose 项目名 `lolping`。运行的配置为 `compose.ip.yaml`、`Caddyfile.ip`，对公网仅发布 TCP 28787。

客户端使用 `wss://18.236.249.217:28787/ws`。1.5.0 App 内置该实例的公开根证书，证书信任限定到这个 IP 与端口。Caddy 自动续期服务证书，客户端继续校验证书链、主机名和有效期。根证书不写入 Mac 系统钥匙串。

维护命令：

```sh
cd /opt/lolping/current
docker compose -p lolping -f compose.ip.yaml ps
docker compose -p lolping -f compose.ip.yaml logs --tail=100
docker compose -p lolping -f compose.ip.yaml up -d --build
```

保留 `lolping_caddy_data` 卷，其中保存此实例的证书机构与私钥。更新、重建容器时沿用这个卷。删除此卷或迁移到另一台服务器时，需通过可信 SSH 重新获取公开根证书、更新客户端的 `Resources/RelayTrust` 并重新签名打包；不要通过未经验证的网络自动下载并信任新根证书。

`compose.ip.yaml` 是此实例的固定配置。部署新的实例时，需要独立证书机构和对应客户端配置，或使用下述标准域名 HTTPS 部署。

## 全新服务器：Docker Compose + 自动 HTTPS

准备一台 Linux 公网服务器、Docker 和 Compose 插件，以及一个域名。将域名 A 记录解析到服务器公网 IP；只有服务器确实支持 IPv6 时才设置 AAAA 记录。服务器和云安全组需允许 TCP 80、443，且这两个端口没有被其他服务占用。

上传并解压部署包，进入包含 `compose.yaml` 的目录：

```sh
cp .env.example .env
```

编辑 `.env`，填真实域名，不带 `https://`、路径或端口：

```dotenv
PING_DOMAIN=ping.your-domain.com
```

启动并检查：

```sh
docker compose config --quiet
docker compose up -d --build
docker compose ps
docker compose logs --tail=50
curl https://ping.your-domain.com/health
```

正常返回 `{"status":"ok","protocol":1}`。两台 Mac 均填写 `wss://ping.your-domain.com/ws`。Caddy 自动申请、续期 HTTPS 证书，并转发 WebSocket。8787 只在容器内部使用，无需向公网开放。

如果首次证书申请未完成，可查看 `docker compose logs --tail=100 caddy`，检查域名解析和 80/443 的可达性。

## 已有 Nginx/Caddy：只运行中继

已有网站或面板占用了 80/443 时，使用独立配置，保留现有反向代理：

```sh
docker compose -f compose.proxy.yaml up -d --build
curl http://127.0.0.1:8787/health
```

在已有 HTTPS 站点中加入 `nginx.example.conf` 的两个 location，然后检查并重载 Nginx。配置中的 `X-Forwarded-For $remote_addr` 必须保留。已有 Caddy 可使用：

```caddyfile
ping.your-domain.com {
    reverse_proxy 127.0.0.1:8787 {
        header_up X-Forwarded-For {remote_host}
    }
}
```

中继绑定宿主机回环地址，仅能由本机反向代理访问。Compose 开启 `TRUST_PROXY=1`，按代理传入的真实客户端 IP 限制连接数；代理必须覆盖传入的 X-Forwarded-For，且不要把 8787 改成对公网监听。

## 客户端使用

两人安装 LoLPing 1.5.0，打开“服务器联机”开关，填写同一 `wss://域名/ws` 和各自昵称。一人创建房间，另一人输入生成的 12 位房间码加入。点击“发送测试信号”后，朋友会在主屏幕中央看到信号和发送者名字。开启本机 Ping 并允许辅助功能后，也可用快捷键发送九种信号。接收方无需辅助功能权限。关闭服务器联机立即退出房间并停止自动重连；开启局域网会关闭服务器联机。自定义快捷键在 Mac 客户端设置，服务器协议保持为 1，已有 1.3.1 客户端仍兼容。

## 无域名：通过 SSH 隧道使用

如果暂时没有域名，先用 `compose.proxy.yaml` 启动中继。两位使用者分别在自己的 Mac 上运行：

```sh
ssh -N -L 8787:127.0.0.1:8787 用户名@服务器IP
```

保持终端连接，两台 Mac 的 App 都填 `ws://127.0.0.1:8787/ws`，然后创建/加入同一房间。这种方式需要每位使用者自己的服务器 SSH 登录权限。网络通信由 SSH 隧道加密，客户端的明文 ws 地址只用于本机回环连接。

## 运行维护

```sh
docker compose logs --tail=100 relay
docker compose up -d --build   # 更新代码后的重新构建
docker compose down           # 停止；保留 Caddy 证书卷
```

如果使用已有代理方案，上述命令加 `-f compose.proxy.yaml`。

- 每个房间最多两人；断线成员席位保留 60 秒并自动重连。
- 所有房间仅在单个中继进程内存中存在，服务重启后需重新创建，不要负载均衡到多个独立实例。
- 信号只发给同一房间的在线朋友，不回传给发送者，不补播断线期间的旧信号。
- TLS 在反向代理终止，中继可以读取信号，不把信号或房间凭证写入消息日志。
- 内置消息大小、发送频率、连接数限制、心跳和事件去重；容器附带健康检查并以普通用户运行。

## 自定义表情协议

协议版本仍为 1，通过 `hello.capabilities: ["emote-png-v1"]` 协商图片能力。旧客户端继续互发 Ping，不接收未知表情消息。`emote` 事件附带 UUID、名称、PNG 的 Base64 和 SHA-256；发送者身份由服务器绑定。

图片最多 32 KB、160 × 160，WebSocket 总帧最多 48 KB。服务器校验 PNG 头、尺寸、哈希和编码，接收端再次解码并校验。每人表情限速一张/秒，并保留连接字节预算、消息限速、事件去重和输出缓冲限制。图片只转发给同房间在线且支持表情的朋友，不落盘、不缓存、不补播；断线重连后可继续发送。

## 开发验证

Node.js 22 或更新版本：

```sh
npm ci --ignore-scripts
npm test
node test/emote-client-check.mjs ../dist/LoLPing.app/Contents/MacOS/LoLPing
npm start
```

本机测试地址为 `ws://127.0.0.1:8787/ws`。公网必须使用 `wss://`，客户端不会连接公网明文 WebSocket。

在 Mac 的源码仓库先执行 `zsh scripts/build.sh`，再到 `relay/` 执行 `npm run test:swift`，可验证生产版客户端的房间创建/加入、双向发送、接收开关、身份恢复和离开房间。不监听全局按键、不显示动画、不播放音效、不读写用户偏好。

部署依赖说明：[Caddy reverse_proxy 官方文档](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)，[ws 官方版本记录](https://github.com/websockets/ws/releases)。

此实例的专用连接使用 Network.framework 的 TLS WebSocket，TLS 最低版本为 1.2，并用指定 CA 验证证书链、IP 与有效期。App 的 ATS 保持默认，未添加 HTTP 例外。参考 [Apple WebSocket 文档](https://developer.apple.com/documentation/network/nwprotocolwebsocket) 和 [Apple 信任锚文档](https://developer.apple.com/documentation/security/sectrustsetanchorcertificates(_:_:))。
