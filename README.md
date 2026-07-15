# Run Log

个人跑步档案馆 — 记录马拉松比赛、日常训练、路线轨迹与年度跑量。项目使用纯 HTML/CSS/JavaScript，无构建步骤，支持亮暗主题以及 GitHub Pages / GitLab Pages 部署。

## 页面结构

单页应用，顶部导航切换三个面板：

| 标签 | 内容 |
|------|------|
| **路线** | 路线缩略图列表，支持日常 / 长距离 / 比赛筛选、分批加载和当前筛选路线叠图 |
| **比赛** | 全马 / 半马分组卡片，含路线预览、成绩、配速，点击路线直接在地图展示 |
| **统计** | 年度跑量、月度柱状图、比赛数量、月均跑量、最长距离和每月训练明细 |

地图上方浮动显示 5 项关键指标：累计里程、年度跑量、全马 PB、半马 PB、完赛场次。

点击路线或比赛记录后，地图会显示轨迹和心率、配速、用时、爬升等统计。手机端曲线图默认折叠，完整路线数据在后台读取，只有手动展开时才创建配速、海拔和心率曲线，避免首次点击时发生布局闪烁。

## 快速开始

```bash
python3 -m http.server 8080
# 浏览器打开 http://localhost:8080
```

无需构建工具，无需 npm install。

## 目录结构

```
index.html                 # 入口页面
app.js                     # 主逻辑：数据计算、面板、地图和曲线图
styles.css                 # 亮暗主题与响应式样式
data.generated.js          # 自动生成：个人资料、跑步与比赛数据（紧凑格式）
route-index.generated.js   # 自动生成：路线预览索引（紧凑格式）
city-boundaries.generated.js # 自动生成：比赛城市 GeoJSON 边界
routes/*.js                # 每条路线的完整 GPS 坐标（按需加载）
sync/
  apple-health-import.py   # Apple Health 导出 → 生成数据文件
  strava-sync.mjs          # Strava API → 生成数据文件
assets/                    # 静态资源（头像、本地 Chart.js 等）
```

## 数据维护

### Apple Health 导入

```bash
python3 sync/apple-health-import.py /path/to/apple_health_export.zip
```

脚本自动生成紧凑格式的 `data.generated.js`、`route-index.generated.js` 和 `routes/*.js`。

### Strava 同步

1. Apple Watch 记录跑步 → 通过 Strava / HealthFit / RunGap 同步到 Strava
2. 编辑 `sync/strava-sync.mjs`，填入 API 凭证后运行

### 比赛判定规则

脚本和前端采用相同的过滤逻辑，避免晚间长距离训练被误判为比赛：

1. **距离**：41-44km → 全马，20-23km → 半马
2. **时间**：只保留上午（开始时间早于 12:00）的记录。从 `sourceRunId`（格式 `apple-YYYYMMDD-HHMMSS`）中提取开始小时

## 路线隐私

同步脚本会先裁剪每条路线首尾若干坐标点，再生成路线预览和 `routes/*.js` 公开路线文件。页面会标注隐私半径，完整精度的公开路线仅在点击路线或手动展开曲线时按需加载。

## 性能与交互

- 路线列表首次渲染 80 条，可继续分批显示，避免一次创建全部列表节点
- `data.generated.js` 和 `route-index.generated.js` 使用紧凑 JSON，减少静态资源体积
- 路线预览来自轻量索引，完整轨迹与时间序列按路线加载并缓存
- Chart.js 随项目本地加载，外部 CDN 仅作为容错来源
- 手机端点击记录时不创建曲线画布；后台数据就绪后仍保持折叠，手动展开才渲染图表
- 路线、比赛和统计标签切换时会清理上一页面的选中记录与图表状态

## 部署

### GitHub Pages

仓库设置 → Pages → Source: `Deploy from a branch` → Branch: `main`, `/ (root)`。

### GitLab Pages

仓库已包含 `.gitlab-ci.yml`，推送到 `main` 分支后自动部署。网站地址：`https://<用户名>.gitlab.io/running-archive/`。

```bash
git remote add gitlab https://gitlab.com/<用户名>/running-archive.git
git push gitlab main
```

两个远程互不冲突，同一份代码可以同时推送到 GitHub 和 GitLab。

### Cloudflare Pages

Cloudflare Pages 可直接连接 GitHub 仓库部署，构建命令留空，输出目录使用仓库根目录。

页面默认使用 Leaflet + CartoDB/OpenStreetMap，以保持当前清淡地图视觉风格。

如需临时验证高德 Web 端 JS API，可在当前域名的浏览器控制台开启：

```js
localStorage.setItem("RUN_USE_AMAP", "true");
```

关闭高德验证并恢复默认 Leaflet：

```js
localStorage.removeItem("RUN_USE_AMAP");
```

Cloudflare 域名 `running-archive.pages.dev` 开启高德验证时，会通过 Pages Function 代理高德安全请求。高德安全密钥不要提交到仓库，需要在 Cloudflare Pages 的环境变量中配置：

```text
AMAP_SECURITY_JSCODE=<高德安全密钥>
```

本地或 GitHub Pages 验证高德时，还需要临时设置安全密钥：

```js
localStorage.setItem("RUN_AMAP_SECURITY_JSCODE", "<高德安全密钥>");
```

清除本地调试密钥：

```js
localStorage.removeItem("RUN_AMAP_SECURITY_JSCODE");
```

## 技术栈

- **地图**：默认使用 Leaflet.js，CartoDB 瓦片优先，加载失败时自动切到 OpenStreetMap；可通过本地开关临时验证高德 Web 端 JS API
- **资源容错**：Chart.js 使用仓库内本地文件并保留 CDN 回退；Leaflet 依次尝试多个 CDN，地图瓦片可从 CartoDB 回退至 OpenStreetMap
- **路线缩略图**：内联 SVG，Mercator 投影，亮暗主题独立配色，亮色模式使用浅色渐变底
- **面板交互**：路线 / 比赛列表支持折叠和拖拽调整高度；路线页提供距离类型筛选和筛选叠图；手机端统计条停在底部记录列表上方
- **样式**：CSS 自定义属性、backdrop-filter 毛玻璃、CSS Grid/Flexbox
- **数据加载**：完整 GPS 坐标通过动态 `<script>` 注入按需加载
- **零依赖**：不依赖任何框架或构建工具

## 检查

```bash
node --check app.js
node --check assets/chart.umd.min.js
python3 -m py_compile sync/apple-health-import.py
node --check sync/strava-sync.mjs
```
