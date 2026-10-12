#!/bin/zsh
# LoLPing 一键安装：复制到「应用程序」，去掉下载隔离标记，然后打开。
HERE="${0:A:h}"
SRC="$HERE/LoLPing.app"
print ""
print "==== LoLPing 一键安装 ===="
if [[ ! -d "$SRC" ]]; then
    print "没找到 LoLPing.app。请先把 ZIP 完整解压，install.command 要和 LoLPing.app 在同一个文件夹里。"
    exit 1
fi

if pgrep -x LoLPing >/dev/null 2>&1; then
    print "正在退出正在运行的 LoLPing…"
    osascript -e 'tell application id "local.allentu.LoLPing" to quit' >/dev/null 2>&1 &
    QUIT_PID=$!
    for i in {1..6}; do pgrep -x LoLPing >/dev/null 2>&1 || break; sleep 0.5; done
    kill $QUIT_PID >/dev/null 2>&1
    pkill -x LoLPing >/dev/null 2>&1
    sleep 0.5
fi

install_to() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || return 1
    [[ -w "$dir" ]] || return 1
    rm -rf "$dir/LoLPing.app" 2>/dev/null
    ditto "$SRC" "$dir/LoLPing.app" 2>/dev/null || return 1
    DEST="$dir/LoLPing.app"
}
DEST=""
if ! install_to /Applications; then
    print "「应用程序」文件夹没有写入权限，改为安装到个人的 ~/Applications。"
    if ! install_to "$HOME/Applications"; then
        print "安装失败：无法复制 LoLPing.app。可以手动把 LoLPing.app 拖进「应用程序」文件夹。"
        exit 1
    fi
fi
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1
print "已安装到：$DEST"
open "$DEST"

print ""
print "接下来："
print "1. 第一次打开时，如果弹出「允许 LoLPing 查找本地网络上的设备」，点「允许」；"
print "   如果弹出防火墙「是否允许传入网络连接」，也点「允许」。"
print "2. 跨网络使用：在「服务器联机」中填写相同的 wss://服务器域名/ws，一人创建房间，另一人输入 12 位房间码加入。"
print "3. 显示「已连接：朋友的名字」后点「发送测试信号」检查联动；同一 Wi-Fi 也可切换使用「局域网联机」。"
print "4. 自己发信号要打开「启用 Ping」并允许辅助功能，然后按住 Control + Option + Command 选择信号；"
print "   只接收朋友的信号不需要辅助功能。"
print "窗口关掉后，LoLPing 会留在屏幕顶部菜单栏（圆形定位图标）。现在可以关闭这个终端窗口了。"
