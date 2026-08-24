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

## 同步历史记录

“授权并检查新增跑步”会读取 HealthKit 中的全部跑步，不再只查最近 30 条。为了避免
误操作，App 默认仅预选最近 30 条；需要重传旧数据时可以逐条选择，或点击“全选”。
上传会逐条执行，每条成功后立即保存进度，中途失败时无需从头开始。完成状态会显示
“覆盖”和“新增”的数量；旧记录正常匹配时应计入“覆盖”。

HealthKit 会将几个月前的第一方 Workout 高频心率和功率压缩到少数 quantity-series
容器。App 使用 `HKQuantitySeriesSampleQuery` 展开容器中的明细和连续区间；否则一场
运动可能只上传 2–9 个外层容器，网页就会画成近似直线。安装包含该修复的版本后，
App 会把 2026-04-25 及以前曾同步过的记录重新列为待同步；再次上传会覆盖对应记录
并修复曲线，不会产生重复跑步。同步状态会显示本批实际读取的心率点数。

较老的 Workout 可能仍存在，但 HealthKit 已无法返回它的路线、功率或步数，并报告
`HKErrorNoData`。App 会把这些附属数据视为可选项，继续上传其余可用内容；某一条
出现其他错误时也只保留该条等待重试，不会阻断后面的已选记录。服务器只用非空新
指标覆盖旧指标，并可将新心率合并到已有路线，不会因为缺少新路线而清空旧路线。

手机同步与 Apple Health 全量导入使用相同的 `apple-YYYYMMDD-HHMMSS` 稳定 ID，
所以重传会覆盖同一次跑步的旧数据，不会新增一份重复记录。服务端也会通过
`sourceRunId` 识别既有比赛，只更新比赛及其高采样率路线、心率数据，不会再创建
一条普通跑步。后续网页部署和数据库迁移会继续保留这些 HealthKit 数据。

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
