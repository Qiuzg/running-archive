# Running Archive Sync for iPhone

这是一个只面向个人使用的 SwiftUI + HealthKit 同步工具。它读取 Apple Watch 写入
健康数据库的跑步、路线与心率数据，并增量上传到 Running Archive。

## 运行

1. 从 App Store 安装完整 Xcode。
2. 在 Xcode 中直接打开本目录的 `RunningArchiveSync.xcodeproj`，不要选择整个网页仓库作为工程。
3. 在 Target → Signing & Capabilities 中选择自己的 Personal Team。
4. 使用数据线连接 iPhone，并在手机上开启“开发者模式”。
5. 在真机上运行。HealthKit 数据不能在普通模拟器中完整验证。

免费 Personal Team 的签名约 7 天后失效，到期后重新连接手机，在 Xcode 中运行一次即可。

工程在网页仓库中的完整相对路径是：

```text
running-archive/ios/RunningArchiveSync/RunningArchiveSync.xcodeproj
```

## 服务端

服务器必须配置 `RUNNING_SYNC_TOKEN`，App 中填写同一个值：

```bash
sudo sh -c 'printf "%s\n" "RUNNING_SYNC_TOKEN=换成至少32位随机字符串" > /etc/running-archive.env'
sudo chmod 600 /etc/running-archive.env
sudo systemctl restart running-archive
```

建议只填写 HTTPS 地址。App 不允许通过公网明文 HTTP 发送同步令牌。
