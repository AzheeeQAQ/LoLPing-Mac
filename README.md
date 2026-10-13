# LoLPing Mac 1.4.0 · 服务器联机版

在 Mac 桌面发送和接收 Ping。支持同一 Wi-Fi 的局域网直连，以及不同网络之间的服务器房间联机。

客户端保留局域网直连，并提供加密的 WebSocket 房间中继。客户端要求 macOS 13 或更新版本，安装包同时支持 Apple 芯片和 Intel。

## 当前服务器

已部署的服务器地址为 `wss://18.236.249.217:28787/ws`。1.4.0 客户端已预填这个地址，并内置该服务器专用的公开根证书。只需 TCP 28787，不需要额外开放证书签发端口，也不需要安装系统根证书。

双方使用 1.4.0 安装包，打开“服务器联机”开关，一人创建房间，另一人填 12 位房间码加入。该私有证书信任只对内置的服务器 IP 与端口生效，仍验证证书链、IP 地址和有效期；其他服务器沿用系统 HTTPS 校验。

## 完整安装包

[下载 1.4.0 完整 PKG 安装包](downloads/LoLPing-v1.4.0-complete-macOS-universal.pkg)。双击后按 macOS 安装向导操作，固定安装到 `/Applications/LoLPing.app`，自动备份并原子替换旧版，保留个人设置。旧版备份在 `/Library/Application Support/LoLPing/InstallerBackups`。

安装包包含全部图标、动画、音效、服务器公开根证书及预填地址，无需另外安装运行环境。通过快捷键发送时需使用者手动允许辅助功能。若旧授权开关已打开但仍提示未授权，移除旧条目，重新添加 `/Applications/LoLPing.app` 并允许，然后重新打开 App。

当前 PKG 尚未使用 Apple Developer ID 签名或公证；若 macOS 拦截，请在“系统设置 → 隐私与安全性”对该安装包允许打开。安装程序不会自动修改系统隐私权限。

## 跨网络联机

1. 先按 [服务器部署说明](relay/README.md) 部署中继。
2. 双方安装 **1.4.0 服务器联机版**，打开“服务器联机”开关，填写相同的服务器地址，例如 `wss://ping.example.com/ws`，并填写各自昵称。
3. 一人点击“创建房间”，将 12 位房间码分享给朋友；另一人输入房间码后点击“加入房间”。
4. 显示“已连接：朋友的名字”后，点击“发送测试信号”检查连接。
5. 使用快捷键发送时，开启“启用 Ping”并允许辅助功能，默认按住 Control + Option + Command，移动选择信号后松开；也可点击“触发组合键”旁的“自定义…”修改。

朋友的信号在接收者主屏幕中央显示，并带上发送者名字。只接收信号不需要辅助功能权限。“接收朋友信号”和“静音朋友”可分别控制显示与音效；关闭本机 Ping 不会关闭接收。

服务器联机和局域网联机开关互斥。关闭服务器联机立即退出房间、清除朋友效果并停止收发和自动重连；重新开启后需创建或加入房间。开关偏好会保存，重启 App 不自动加入房间。局域网仍使用原来的 4–8 位房间码和相对屏幕坐标；服务器房间使用中继生成的 12 位房间码。

## 自定义组合键

点击“触发组合键”旁的“自定义…”，选择 Control / Option / Shift / Command；可以仅用两个或更多修饰键，也可用一个或更多修饰键搭配字母、数字、空格、方向键或 F 键。支持恢复默认，保存后立即生效并记住设置。旧版三种预设会自动保留。

搭配普通按键时先按修饰键，再按住所选按键 0.18 秒，移动选择后松开任意一个键发送。短按不发送，Esc / 右键取消；重复按键和不同松键顺序只提交一次。设置窗口打开时暂停全局输入，保存或取消后恢复。

[下载 1.4.0 通用安装包](downloads/LoLPing-v1.4.0-server-macOS-universal.zip)

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
# 从仓库根目录检查联机开关和按键路由（仅创建临时测试房间）：
# dist/LoLPing.app/Contents/MacOS/LoLPing --feature-check wss://18.236.249.217:28787/ws
cd ..
zsh scripts/package.sh   # 通用 App 和 ZIP
zsh scripts/package-installer.sh  # 完整 PKG：固定安装路径、旧版备份和授权引导
```

源码包括 `Sources/LoLPing/RelayClient.swift`、`Sources/PingCore/RelayProtocol.swift` 及整个 `relay/` 目录。网络中只转发信号类型、事件 ID 和发送者，不同步桌面、鼠标位置或按键内容。中继只在内存中保存房间；重启后需重新创建房间，断线期间的信号不补播。房间最多两人，掉线成员席位保留 60 秒。

## 旧版局域网安装包

[LoLPing-LAN-v1.2.0.zip](https://github.com/AzheeeQAQ/LoLPing-Mac/raw/refs/tags/v1.2.0-lan/downloads/LoLPing-LAN-v1.2.0.zip) 是旧版，仅支持局域网。根目录 `SHA256SUMS` 包含旧版和当前安装包的校验值。服务器联机需要使用新构建的 1.4.0 客户端。

原始桌面工具基于 [AllenTHT/LoLPing-Mac](https://github.com/AllenTHT/LoLPing-Mac)。本工具非 Riot 官方产品，游戏素材归 Riot Games 所有。
