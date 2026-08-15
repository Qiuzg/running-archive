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

单页应用，顶部导航切换三个面板：

| 标签 | 内容 |
|------|------|
| **路线** | 路线缩略图列表，支持日常 / 长距离 / 比赛筛选、分批加载和当前筛选路线叠图 |
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

同步脚本会裁剪每条路线首尾若干坐标点，再生成路线预览和完整路线文件。页面会标注隐私半径，完整轨迹与时间序列只在需要时由 API 返回。

## 部署

部署脚本会重新构建前端、同步 `dist/`、`server/`、生成数据和 `routes/` 到服务器，然后在远端备份旧数据库并重新运行迁移。有服务器地址参数时，默认以 `BASE_PATH=/run/` 构建，匹配当前 nginx 的 `https://<host>/run/` 入口。

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
