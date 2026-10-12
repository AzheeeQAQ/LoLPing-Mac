# LoLPing Mac 1.3.1 · 服务器联机版

在 Mac 桌面发送和接收 Ping。支持同一 Wi-Fi 的局域网直连，以及不同网络之间的服务器房间联机。

本版基于仓库最新的局域网源码 `405135d`，合并“实现 LoLPing-Mac 跨电脑联动”中的 WebSocket 房间中继方案。客户端要求 macOS 13 或更新版本，安装包同时支持 Apple 芯片和 Intel。

## 当前服务器

已部署的服务器地址为 `wss://18.236.249.217:28787/ws`。1.3.1 客户端已预填这个地址，并内置该服务器专用的公开根证书。只需 TCP 28787，不需要额外开放证书签发端口，也不需要安装系统根证书。

双方使用 1.3.1 安装包，一人创建房间，另一人填 12 位房间码加入。该私有证书信任只对内置的服务器 IP 与端口生效，仍验证证书链、IP 地址和有效期；其他服务器沿用系统 HTTPS 校验。

## 跨网络联机

1. 先按 [服务器部署说明](relay/README.md) 部署中继。
2. 双方安装 **1.3.1 服务器联机版**，填写相同的服务器地址，例如 `wss://ping.example.com/ws`，并填写各自昵称。
3. 一人点击“创建房间”，将 12 位房间码分享给朋友；另一人输入房间码后点击“加入房间”。
4. 显示“已连接：朋友的名字”后，点击“发送测试信号”检查连接。
5. 使用快捷键发送时，开启“启用 Ping”并允许辅助功能，按住 Control + Option + Command，移动选择信号后松开。

朋友的信号在接收者主屏幕中央显示，并带上发送者名字。只接收信号不需要辅助功能权限。“接收朋友信号”和“静音朋友”可分别控制显示与音效；关闭本机 Ping 不会关闭接收。

服务器联机和局域网联机切换使用，避免同一条信号被重复发送。局域网仍使用原来的 4–8 位房间码和相对屏幕坐标；服务器房间使用中继生成的 12 位房间码。

## 服务器部署

服务器使用 Node.js WebSocket 中继，Docker Compose 配套 Caddy 申请 HTTPS 证书。详见 [relay/README.md](relay/README.md)。服务器运行中继，桌面动画与音效由两台 Mac 本地显示、播放。

```sh
cd relay
cp .env.example .env
# 将 .env 中的 PING_DOMAIN 修改成已解析到服务器的真实域名。
docker compose up -d --build
```

已有 Nginx/Caddy 的服务器使用 `compose.proxy.yaml`，中继只绑定服务器的 `127.0.0.1:8787`，不会抢占 80/443。

## 构建与验证

Mac 客户端需要 Swift 命令行工具。服务器需要 Node.js 22 或更新版本，Docker 镜像使用 Node.js 24。

```sh
zsh scripts/test.sh       # 手势、局域网和服务器协议检查
zsh scripts/build.sh      # 构建 dist/LoLPing.app
cd relay
npm ci --ignore-scripts
npm test                 # 中继服务测试
npm run test:swift       # 真实生产版 Swift 客户端集成检查
cd ..
zsh scripts/package.sh   # 通用安装包：dist/LoLPing-v1.3.1-server-macOS-universal.zip
```

源码包括 `Sources/LoLPing/RelayClient.swift`、`Sources/PingCore/RelayProtocol.swift` 及整个 `relay/` 目录。网络中只转发信号类型、事件 ID 和发送者，不同步桌面、鼠标位置或按键内容。中继只在内存中保存房间；重启后需重新创建房间，断线期间的信号不补播。房间最多两人，掉线成员席位保留 60 秒。

## 旧版局域网安装包

[LoLPing-LAN-v1.2.0.zip](https://github.com/AzheeeQAQ/LoLPing-Mac/raw/refs/tags/v1.2.0-lan/downloads/LoLPing-LAN-v1.2.0.zip) 是旧版，仅支持局域网。根目录 `SHA256SUMS` 对应这个保留的旧版文件。服务器联机需要使用新构建的 1.3.1 客户端。

原始桌面工具基于 [AllenTHT/LoLPing-Mac](https://github.com/AllenTHT/LoLPing-Mac)。本工具非 Riot 官方产品，游戏素材归 Riot Games 所有。
