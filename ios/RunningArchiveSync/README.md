# Running Archive for iPhone

这是一个只面向个人使用的原生 SwiftUI 跑步档案 App。界面沿用手机网页端的地图、
指标卡片和路线面板风格，同时保留 Apple Watch / HealthKit 增量同步能力。

手机客户端的完整说明见 [MOBILE_CLIENT.md](MOBILE_CLIENT.md)。

## App 功能

- **档案**：地图铺满首屏，叠加头像、年度跑量、全马/半马 PB，并在此提供全局日间/夜间切换。
  总览会合并地理覆盖高度相似的路线，将代表轨迹合并为一个 MapKit 图层；拖动地图时，后台路线扫描产生的图层更新会延迟到手势结束，避免抢占交互。
- **汇总**：展示总跑量、年度月度跑量、可点选月份的每日数据，以及 10 km 以上路线汇总和导出。
- **记录**：按全部、训练或比赛筛选，查看真实路线预览、详情地图、配速、海拔和心率趋势。配速优先读取 HealthKit 跑速，并将更快的配速绘制在折线图上方。
- **分享**：选择任意带路线的记录，手动生成 1080×1400 精简图或 1080×2800 详细图，
  可自定义标题、选择 Leaflet/高德地图和日间/夜间样式，支持直接保存到相册或通过 iOS
  分享面板发送给其他 App；分享图与详情页共用处理后的配速数据和折线呈现，地图仍会隐藏路线首尾各 600 米，避免暴露常用起终点。
- **同步**：授权读取 HealthKit，选择一条或多条跑步，分条上传到 Running Archive。

档案、记录、详情和分享全部直接读取这台 iPhone 中的 Apple Health 数据，不依赖网站
数据库。跑步摘要会立即用于计算累计里程、年度跑量和 PB；路线在后台逐条整理，结果与
按需读取的心率、功率明细会缓存在 SwiftData 中，因此首次运行后打开速度会明显加快。
服务器地址只用于“同步”标签中的可选上传，不影响 App 本地查看和分享。

移动端 Leaflet 分享固定使用与网页详细分享图一致的 CARTO `light_all` / `dark_all`
瓦片。`CARTOAPIKey` 配置在 App 的 `Info.plist` 中；如果 Key 缺失或瓦片加载不完整，
App 会直接提示失败，不会静默换成 OSM 或高德底图。高德选项仍独立使用高德瓦片，
并只在该模式下把路线坐标转换为 GCJ-02。

## 运行

1. 从 App Store 安装完整 Xcode。
2. 在 Xcode 中直接打开本目录的 `RunningArchiveSync.xcodeproj`，不要选择整个网页仓库作为工程。
3. 在 Target → Signing & Capabilities 中选择自己的 Personal Team。
4. 使用数据线连接 iPhone，并在手机上开启“开发者模式”。
5. 在真机上运行。新版所有页面都以 Apple Health 为数据源，模拟器只能验证空数据界面。

免费 Personal Team 的签名约 7 天后失效，到期后重新连接手机，在 Xcode 中运行一次即可。

首次授权后，记录列表和统计会先出现，路线图随后在后台逐条补齐。历史记录较多时可以
正常离开当前页面，已经读取的路线不会丢失；下次启动会从 SwiftData 缓存继续整理。

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

对于包含活动/休息段的间歇训练，App 还会读取 HealthKit 的 `workoutActivities`；如果记录
只有 lap/segment 事件，则保存这些事件的时间范围。活动段会一并计算该段的距离、配速、
心率、步频和功率，服务端保存后可用仓库根目录的 `scripts/export-running-records.py`
通过 `--segments-output` 导出。仅有事件时间而没有活动统计的记录，对应指标会留空。

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

同步失败时，顶部状态卡会完整显示首个错误，并可展开、选择全部错误详情。服务器返回的
FastAPI `detail` 会被提取成可读信息；数据库不可写或繁忙时接口返回 503，而不是只有
无法定位原因的 500。SQLite 除了数据库文件本身，还要求 `server/` 父目录允许
`www-data` 创建 journal/WAL 文件；正式部署脚本会自动校验这项权限。
