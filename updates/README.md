# 发布应用内更新

1.6.0 起内置 Sparkle 2.10.0。默认启动和每小时检查，用户可以关闭；自动检查只显示控制窗口 / 菜单栏提醒，点击“立即更新”后使用 Sparkle 的下载、签名验证、替换和重启流程，无需再次点击重启。自动安装默认关闭，游戏期间不会强制重启。更新只替换 App，偏好和用户表情位于用户 Library，重启后需重新加入房间。

生产更新源为 `https://raw.githubusercontent.com/AzheeeQAQ/LoLPing-Mac/main/updates/appcast.xml`，更新 ZIP 使用同一仓库的不可变版本 tag。App 只包含公开 Ed25519 key；私钥长期保存在发布者本机登录钥匙串，account 为 `local.allentu.LoLPing`，绝不能提交或上传私钥。首次生成可以使用已由 SwiftPM 校验下载的 `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.allentu.LoLPing`，已有 key 时不会替换。若无界面会话无法让签名工具访问钥匙串，可在权限为 0700 的临时目录导出本机专用 key，设置 `LOLPING_UPDATE_KEY_FILE` 为其路径，完成签名立即删除临时 key；这个可选文件绝不能上传。保留并安全备份钥匙串，当前版本不支持丢失密钥后继续签发更新。

下次发布：

1. 修改 `Resources/Info.plist` 的展示版本及递增整数 `CFBundleVersion`，编写 `updates/release-notes/<版本>.txt`。
2. 运行 `zsh scripts/package.sh`、`zsh scripts/package-installer.sh`，验证通用 App 和安装包。
3. 运行 `zsh scripts/package-update.sh updates/release-notes/<版本>.txt`。工具从钥匙串签名 ZIP 和 feed，生成只包含 `LoLPing.app` 的更新包。已有版本的发布 ZIP 不允许覆盖。不要在签名后手动编辑 feed。
4. 将新的安装包、更新 ZIP、签名 feed 和源码提交到同一 Git commit，创建 `v<版本>` tag，使用 `git push --atomic origin HEAD:main v<版本>` 一起推送。feed 中的版本 tag 必须与发布 tag 完全一致。
5. 从公开 HTTPS 地址重新下载 feed / ZIP 并验证签名，使用较早版本的带更新器 App 验证实际更新。

工具和版本由 `Package.swift` / `Package.resolved` 锁定，框架及嵌套辅助进程由打包脚本完整嵌入。保留 Sparkle 许可证。开启 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，篡改 feed 或 ZIP 会拒绝更新；没有 ATS 放行或系统信任变更。

1.5.1 及以前没有更新器，首次需安装 1.6.0 完整 PKG，此后可在应用里更新。当前 App 是 ad hoc 签名，尚未 Apple Developer ID 签名和公证；系统可能需要手动允许首次打开、管理员安装确认或重新授权辅助功能。Sparkle 的更新签名不能替代 Apple 公证。
