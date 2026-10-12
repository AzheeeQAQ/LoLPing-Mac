# LoLPing Mac · 局域网互发版

在同一 Wi-Fi 下和朋友互发桌面 Ping 信号。

## 下载和安装

- [下载 LoLPing-LAN-v1.2.0.zip](https://github.com/AzheeeQAQ/LoLPing-Mac/raw/refs/tags/v1.2.0-lan/downloads/LoLPing-LAN-v1.2.0.zip)
- [版本 v1.2.0-lan](https://github.com/AzheeeQAQ/LoLPing-Mac/tree/v1.2.0-lan)
- [完整使用说明](docs/使用说明.txt)

适用于 macOS 13 或更新版本，同时包含 Apple 芯片（arm64）和 Intel（x86_64）版本。应用版本为 1.2.0，构建号为 3。

1. 下载并完整解压 ZIP。
2. 双击 `LoLPing-LAN/install.command`，安装程序会把 App 复制到“应用程序”并打开。
3. 如安装脚本无法打开，可在终端运行 `zsh` 加一个空格，然后把 `install.command` 拖入终端并按回车。
4. 首次使用时允许本地网络访问；发送自己的 Ping 还需在“系统设置 → 隐私与安全性 → 辅助功能”中开启 LoLPing。

## 和朋友联机

双方连接同一 Wi-Fi，打开“局域网联机”，填写相同的房间码和各自的昵称。状态显示“在线：朋友的名字”后即可互发信号。发送信号时，按住 Control + Option + Command，移动鼠标选择信号后松开。

信号在同一局域网内直接传输。只接收朋友的信号不需要辅助功能权限。访客网、校园网等网络可能禁止设备互访。

## 文件校验

发布包保留了提供的原始 ZIP，其可执行文件与已安装版本一致。下载后可运行：

```sh
shasum -a 256 LoLPing-LAN-v1.2.0.zip
```

预期 SHA-256：

```text
46eca8b8816b99ff145e8f0675b4fff99d24874b1d9862ce860265c8f31f35cc
```

也可在仓库根目录运行 `shasum -a 256 -c SHA256SUMS`，校验仓库 `downloads` 目录中的安装包。

## 源码与构建

源码就在本仓库，基于 [AllenTHT/LoLPing-Mac](https://github.com/AllenTHT/LoLPing-Mac) v1.1.0，增加了局域网互发功能。`downloads/` 里的安装包就是用这份源码通过 `scripts/package.sh` 构建的。

需要 macOS 13 或更新版本，以及 Swift 命令行工具（不需要完整 Xcode）。

```sh
zsh scripts/build.sh      # 构建并本地签名 dist/LoLPing.app
zsh scripts/test.sh       # 运行 PingCoreChecks 测试
zsh scripts/package.sh    # 构建 arm64 + x86_64 通用版，打包成 dist/LoLPing-LAN-v1.2.0.zip
```

- 构建脚本带了 `--build-system native`。在部分新版本 Swift 工具链上，默认的 swiftbuild 会报 "Unknown error parsing property list"。
- 局域网实现：Network.framework，Bonjour 服务 `_lolping._udp`，UDP 单播，不经过服务器。代码在 `Sources/LoLPing/LANSession.swift`，协议、坐标换算和限流在 `Sources/PingCore/LAN.swift`。
- 可以在终端里测试联机，不用打开界面：

  ```sh
  dist/LoLPing.app/Contents/MacOS/LoLPing --lan-listen --room 9137 --seconds 20
  dist/LoLPing.app/Contents/MacOS/LoLPing --lan-send --room 9137 --kind retreat --nx 0.25 --ny 0.75
  ```

本工具非 Riot 官方产品，游戏素材归 Riot Games 所有。
