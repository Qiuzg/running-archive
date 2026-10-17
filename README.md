# Run Log

个人跑步档案馆，用来记录马拉松比赛、日常训练、路线轨迹与年度跑量。当前版本使用 Vite 前端 + FastAPI API + SQLite 数据库，数据来源主要是 Apple Health 导出。

## 常用命令

```bash
# 导入最新 Apple Health 数据、迁移数据库、校验并构建
npm run import:apple -- /path/to/apple_health_export
npm run import:apple -- /path/to/apple_health_export.zip

# 本地开发，两个终端分别运行
npm run api
npm run dev

# 构建前端
npm run build

# 同步到服务器，默认部署在 /run/
./server/deploy.sh user@your-server
```

`npm run import:apple` 会先备份当前生成数据和本地 `server/running.db`，然后执行导入、数据库迁移、JS/Python 语法检查、API smoke test 和 Vite 构建。任意一步失败都会恢复备份，避免页面带着损坏数据继续运行。

## 页面结构

单页应用，顶部导航切换四个面板：

| 标签 | 内容 |
|------|------|
| **路线** | 路线缩略图列表，支持日常 / 长距离 / 比赛筛选、分批加载和当前筛选路线叠图 |
| **汇总** | 将超过 10km 的每次跑步轨迹独立归一化，按日常跑 / 半马 / 全马分色排列成路线统计海报 |
| **比赛** | 全马 / 半马分组卡片，含路线预览、成绩、配速，点击路线直接在地图展示 |
| **统计** | 年度跑量、月度柱状图、比赛数量、月均跑量、最长距离和每月训练明细 |

地图上方浮动显示累计里程、年度跑量、全马 PB、半马 PB、完赛场次。点击路线或比赛记录后，地图会显示轨迹和心率、配速、用时、爬升等统计。手机端曲线图默认折叠，只有手动展开时才创建配速、海拔和心率曲线。

## 目录结构

```text
index.html                  # Vite 入口页面
src/                        # 前端模块：状态、地图、面板、统计、路由
styles.css                  # 亮暗主题与响应式样式
server/                     # FastAPI API、SQLite 模型、迁移和部署脚本
scripts/import-apple-health.sh # 一键导入 Apple Health 数据并校验
data.generated.js           # 自动生成：个人资料、跑步与比赛数据
route-index.generated.js    # 自动生成：路线预览索引
city-boundaries.generated.js # 自动生成：比赛城市 GeoJSON 边界
routes/*.js                 # 每条路线的完整 GPS 坐标与时间序列
sync/apple-health-import.py # Apple Health 导出解析脚本
ios/RunningArchiveSync/     # 个人使用的 HealthKit 增量同步 iPhone App
assets/                     # 头像、Chart.js 等静态资源
```

## 数据导入

Apple Health 导出后，直接把导出目录或 zip 路径传给脚本：

```bash
npm run import:apple -- ~/Downloads/apple_health_export
```

脚本会更新：

- `data.generated.js`
- `route-index.generated.js`
- `routes/*.js`
- 本地 `server/running.db`
- `dist/` 构建产物

导入脚本的备份目录是 `sync/backups/`，不会提交到 git。

## 比赛判定规则

脚本和前端采用相同的过滤逻辑，避免晚间长距离训练被误判为比赛：

1. 距离：41-44km 记为全马，20-23km 记为半马
2. 时间：只保留上午开始的记录，开始时间从 `apple-YYYYMMDD-HHMMSS` 中读取，`hour < 12`
3. 比赛名称优先使用 `sync/apple-health-import.py` 里的 `RACE_NAME_OVERRIDES`

## 路线隐私

同步脚本会按路线累计距离裁剪首尾各 600 米，再生成路线预览和完整路线文件。页面会标注隐私半径，完整轨迹与时间序列只在需要时由 API 返回。

## iPhone App、增量同步与图片分享

`ios/RunningArchiveSync/RunningArchiveSync.xcodeproj` 是个人使用的原生 SwiftUI App。
它参考手机网页端设计，包含五个标签页：地图档案、训练汇总、跑步记录、图片分享和
HealthKit 同步。档案、汇总、记录、详情和分享都直接读取手机 Apple Health，不依赖
网页数据库；摘要、路线和明细使用 SwiftData 缓存，冷启动先恢复档案，再后台刷新。分享页由用户手动生成 1080×1440
图文版或 1080×1920 竖屏版，支持 Leaflet/高德、日间/夜间配色、可选档案二维码和 iOS 系统分享。App 分享图展示完整路线；网页导入数据仍按上文规则裁剪。
移动端 Leaflet 固定使用 App 内配置的 CARTO `light_all` / `dark_all` 瓦片，不依赖
服务器配置，也不会在加载失败时静默换成其他地图风格。服务器仅用于可选的网站数据上传。

“汇总”保留月度跑量与月报分享，并增加年度详情和年度分享、AI 训练入口；单次详情支持
同路线对比和跑后手记，更多菜单可进入个人纪录、路线收藏、赛事目标与分析导出。
AI 训练可配置 DeepSeek，查询可用模型，结合近六周跑步、最近三次分段与过程统计、历史 PB、
可读取的恢复背景、目标及可训练时间，分析实际表现并生成新的七天计划。完整提示词和待发送
JSON 可在 App 内查看，API Key 保存在本机钥匙串；模型调用仅在开启 AI 并配置后进行。
“导出分析数据”默认生成可直接交给模型的 Excel，包含逐次记录、公里分段、每 30 秒过程指标、
心率分布、体能参考及指标覆盖率。完整版另附原始 CSV 和完整 GPX；文件在本机生成。

操作、字段口径、分享版式和验证命令见 [手机客户端说明](ios/RunningArchiveSync/MOBILE_CLIENT.md)。

同步页从 HealthKit 读取全部历史跑步、路线、心率、功率与步数，并上传到：

```text
POST /api/sync/apple-workouts
```

服务端必须通过 `/etc/running-archive.env` 配置与 App 相同的 `RUNNING_SYNC_TOKEN`。详细的免费签名和真机安装步骤见 `ios/RunningArchiveSync/README.md`。

App 默认预选最近 30 条，也支持全选历史记录，并逐条断点式上传。手机端与
全量 Apple Health 导入使用相同的确定性记录 ID；历史重传会覆盖同一次跑步，比赛
会更新原有 Race 记录，因此不会重复累计。HealthKit 提供的高采样率路线和心率数据
在之后的数据库迁移与网页部署中优先保留。App 会用 quantity-series 查询展开 HealthKit
对旧 Workout 做过压缩的心率与功率数据，避免只把少数外层容器当作真实采样点上传。
包含多个 HealthKit 活动段、lap 或 segment 事件的间歇训练，也会随同步保存到路线的
`intervals` 字段，供分段导出使用。已经同步过的旧记录不会自动产生分段数据；安装新版
App 后重新同步对应跑步即可。

### 按日期导出跑步与间歇分段

`scripts/export-running-records.py` 会生成一份整次运动汇总 CSV；如需间歇明细，再传入
`--segments-output`（`--intervals-output` 也可），生成一段一行的 CSV：

```bash
python3 scripts/export-running-records.py \
  --start 2026-09-16 --end 2026-09-16 \
  --ssh-host root@your-server \
  --output running-records-2026-09-16.csv \
  --segments-output running-intervals-2026-09-16.csv
```

分段文件包含活动/事件类型、起止秒数、持续时间、距离、配速、平均/最大心率、步频和功率。
旧数据库没有 `intervals` 列时，脚本仍能正常导出汇总，并生成只有表头的分段文件。

网页端的图片分享工具仍然保持隐藏。头像在 4 秒内连续点击 7 次，或访问 `/#/share-lab-7k3m9x2p`，即可选择跑步或比赛并在浏览器本地生成 PNG。App 内分享页则直接显示在底部导航中；选择记录、版式、地图源和配色后手动生成，并可保存到相册或调用 iOS 系统分享。

## 部署

部署脚本会重新构建前端、同步 `dist/`、`server/`、生成数据和 `routes/` 到服务器，然后在远端备份旧数据库并重新运行迁移。有服务器地址参数时，默认以 `BASE_PATH=/run/` 构建，匹配当前 nginx 的 `https://<host>/run/` 入口。

生产环境的 `/run/` 外层代理和 8080 内层 API 都必须允许较大的 HealthKit 请求体。
宿主机外层 `/run/` location 需要设置 `client_max_body_size 25m`；部署脚本会同步内层
`server/nginx-subpath.conf`，避免它回退到 Nginx 默认的 1 MB 限制。

`ios/` 中的 Xcode 源码会提交到 Git，但不属于网页运行文件，部署脚本不会将它上传到服务器。HealthKit App 安装包由本机 Xcode 直接签名并安装到 iPhone。服务器只需要接收同步数据的 FastAPI 接口，并在 `/etc/running-archive.env` 中配置 `RUNNING_SYNC_TOKEN`；未配置令牌不会影响公开网页，只会禁用手机同步接口。

```bash
./server/deploy.sh user@your-server
```

也可以把服务器地址放在环境变量里：

```bash
ECS_HOST=user@your-server ./server/deploy.sh
```

如果未来要部署到根路径，可以显式覆盖：

```bash
BASE_PATH=/ ./server/deploy.sh user@your-server
```

服务器默认目录：

```text
/opt/running-archive
```

如果只运行：

```bash
./server/deploy.sh
```

脚本只会本地构建，并提示本地运行方式。

## 检查

```bash
node --check data.generated.js
node --check route-index.generated.js
node --check app.js
node --check sync/strava-sync.mjs
python3 -m py_compile sync/apple-health-import.py server/migrate.py
npm run build
```
