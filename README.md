# Run Log

个人跑步档案馆 — 记录马拉松比赛、日常训练与年度跑量。纯静态网站，深色运动风主题，支持 GitHub Pages / GitLab Pages 一键部署。

## 页面结构

单页应用，顶部导航切换三个面板：

| 标签 | 内容 |
|------|------|
| **路线** | 左侧滚动列表（SVG 缩略图 + 日期距离），右侧全幅地图实时展示轨迹 |
| **比赛** | 全马 / 半马分组卡片，含路线预览、成绩、配速，点击路线直接在地图展示 |
| **统计** | 全屏年度数据：月度跑量柱状图、年度洞察卡片、每月训练分布明细 |

地图上方浮动显示 5 项关键指标：累计里程、年度跑量、全马 PB、半马 PB、完赛场次。

## 快速开始

```bash
python3 -m http.server 8080
# 浏览器打开 http://localhost:8080
```

无需构建工具，无需 npm install。

## 目录结构

```
index.html                 # 入口页面
app.js                     # 主逻辑（IIFE，约 1715 行）
styles.css                 # 样式表（CSS 自定义属性，约 2969 行）
data.generated.js          # 自动生成：跑步与比赛数据
route-index.generated.js   # 自动生成：路线预览索引
city-boundaries.generated.js # 自动生成：比赛城市 GeoJSON 边界
routes/*.js                # 每条路线的完整 GPS 坐标（按需加载）
sync/
  apple-health-import.py   # Apple Health 导出 → 生成数据文件
  strava-sync.mjs          # Strava API → 生成数据文件
assets/                    # 静态资源（头像等）
```

## 数据维护

### Apple Health 导入

```bash
python3 sync/apple-health-import.py /path/to/apple_health_export.zip
```

脚本自动生成 `data.generated.js`、`route-index.generated.js` 和 `routes/*.js`。

### Strava 同步

1. Apple Watch 记录跑步 → 通过 Strava / HealthFit / RunGap 同步到 Strava
2. 编辑 `sync/strava-sync.mjs`，填入 API 凭证后运行

### 比赛判定规则

脚本和前端采用相同的过滤逻辑，避免晚间长距离训练被误判为比赛：

1. **距离**：41-44km → 全马，20-23km → 半马
2. **时间**：只保留上午（开始时间早于 12:00）的记录。从 `sourceRunId`（格式 `apple-YYYYMMDD-HHMMSS`）中提取开始小时

## 路线隐私

公开页面默认不展示完整路线。同步脚本会裁剪每条路线首尾若干坐标点，页面标注隐私半径。完整 GPS 数据存储在 `routes/*.js` 中，仅点击路线时按需加载。

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

## 技术栈

- **地图**：Leaflet.js（CDN 按需加载），CartoDB 瓦片优先，加载失败时自动切到 OpenStreetMap
- **资源容错**：Leaflet / Chart.js 依次尝试 BootCDN、jsDelivr、unpkg，降低国内访问外部 CDN 时的白屏或缺块概率
- **路线缩略图**：内联 SVG，Mercator 投影，亮暗主题独立配色，亮色模式使用浅色渐变底
- **面板交互**：路线 / 比赛列表支持拖拽调整高度，点击记录后保持用户设置；统计页月记录跳转路线时会恢复默认高度避免遮挡
- **样式**：CSS 自定义属性、backdrop-filter 毛玻璃、CSS Grid/Flexbox
- **数据加载**：完整 GPS 坐标通过动态 `<script>` 注入按需加载
- **零依赖**：不依赖任何框架或构建工具
