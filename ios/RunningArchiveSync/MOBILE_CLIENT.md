# Running Archive 手机客户端

本文档说明 `ios/RunningArchiveSync` 原生 SwiftUI 客户端的功能、数据流、构建方式和常见问题。

## 客户端定位

手机客户端直接读取当前 iPhone 的 Apple Health / HealthKit 数据，不依赖网页端数据库即可查看跑步档案、路线和运动明细。服务器只用于“同步”页面的可选上传。

客户端包含以下页面：

- **档案**：地图、累计里程、全马 PB、半马 PB 和年度统计。
- **汇总**：年度、月份和训练数据统计。
- **记录**：跑步记录列表、筛选、搜索和详情。
- **分享**：生成精简或详细跑步分享图。
- **同步**：选择 HealthKit 跑步并上传到网站。

## 分享图片

分享页不会进入页面就自动生成大图，需要选择记录和设置后点击“生成分享图片”。这样可以避免进入页面时主线程被大图渲染占满。

### 两种版式

- **精简图**：1080 × 1400。包含顶部地图、标题、核心运动数据和二维码页脚，不包含详细折线图。
- **详细图**：1080 × 2800。包含全屏地图、核心数据、配速/海拔/心率折线图和二维码页脚。

生成前可以设置：

- 分享标题，默认“户外跑步”；
- 地图源：Leaflet 或高德；
- 日间/夜间配色。

地图源说明：

- **Leaflet** 使用与网页端相同的 Carto 瓦片和 Web Mercator 投影，使用原始 WGS-84 坐标；
- **高德** 使用高德瓦片，并且只在高德模式下将坐标转换为 GCJ-02，避免 Leaflet 路线偏移；
- 所有地图瓦片加载完成后才会输出图片；网络不完整时会提示切换地图源或重试，不生成残缺地图；
- 地图瓦片带有内存缓存和单瓦片超时，减少重复生成的等待时间。

分享地图默认隐藏路线首尾各 600 米，用于降低常用起终点暴露风险。生成图片后可以点击“保存到相册”，首次使用时需要允许照片写入权限，也可以通过系统分享面板发送给其他 App。

## 数据和性能

- 跑步摘要由 HealthKit 立即提供，路线在后台逐条整理并缓存到 SwiftData；
- 详情页的路线点和配速/心率序列会限制采样数量，避免折线图和地图导致界面卡顿；
- 路线列表使用批量发布，避免每读取一条 HealthKit 路线就重绘整个页面；
- 分享图使用 1.5 倍输出比例，在清晰度和 iPhone 内存占用之间取平衡；
- 生成过程中可以取消任务，切换记录、版式、地图源或配色会使旧图片失效。

## 本地运行

1. 使用 Xcode 打开 `RunningArchiveSync.xcodeproj`，不要打开整个网页仓库作为 Xcode 工程。
2. 在 Target 的 **Signing & Capabilities** 中选择 Personal Team。
3. 使用数据线连接 iPhone，并在设备上打开“开发者模式”。
4. 在真机上运行并授权 HealthKit。

模拟器只能验证空数据界面；路线和 HealthKit 相关功能应在真机上验证。Personal Team 签名通常约 7 天后需要重新运行安装。

## 常见问题

### 分享页一直显示“正在生成分享图片”

当前分享页应由用户手动点击生成。如果地图网络较慢，可以点击“取消生成”，切换地图源后重试。Leaflet 和高德都需要网络访问地图瓦片。

### Leaflet 路线出现偏移

Leaflet 模式必须使用原始 WGS-84 坐标；只有高德模式才使用 GCJ-02 转换。若仍有偏移，请确认运行的是包含地图源选择功能的新版本。

### 地图未完整加载

检查网络后重试，或切换到另一种地图源。客户端会在瓦片缺失时直接报错，不会把半张地图保存为最终图片。

### 保存到相册没有反应

在系统设置中为 Running Archive 开启照片添加权限。客户端使用 `NSPhotoLibraryAddUsageDescription` 请求写入相册，不需要读取相册内容。

### Xcode 命令行构建提示 Simulator runtime 不可用

如果日志包含 `No available simulator runtimes for platform iphonesimulator`，这是本机 Xcode 没安装或无法连接 Simulator runtime；应在 Xcode 中安装对应 runtime，或直接选择已连接的真机运行。该问题与分享页代码无关。

## 主要代码位置

- `RunningArchiveSync/ContentView.swift`：TabView 和页面入口；
- `RunningArchiveSync/ArchiveStore.swift`：HealthKit 数据、SwiftData 缓存和派生统计；
- `RunningArchiveSync/ArchiveViews.swift`：档案、汇总、记录、地图和详情页面；
- `RunningArchiveSync/ShareStudio.swift`：分享页、地图瓦片、分享图片渲染和保存相册；
- `RunningArchiveSync/Info.plist`：HealthKit 与相册写入权限说明。

