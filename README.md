# 跑步档案馆

这是一个静态网页版本的个人跑步档案馆。直接打开 `index.html` 即可查看，也可以部署到 GitHub Pages。

## 数据维护

- `data.js`：比赛、跑步记录、PB 和同步配置。
- `route-index.generated.js`：公开路线索引，不含完整 GPS 坐标，用于快速加载页面。
- `routes/*.js`：每条路线的完整公开轨迹，点击路线时按需加载。
- `app.js`：统计计算、路线绘制、标签切换。

## Apple Watch 自动同步建议

网页不能直接读取 Apple Health。可以选两条链路：

### 不走 Strava API：Apple Health 导出

1. iPhone 打开健康 App。
2. 点右上角头像或姓名缩写。
3. 选择“导出所有健康数据”。
4. 把导出的 zip 放到电脑。
5. 运行：

```bash
python3 sync/apple-health-import.py /path/to/apple_health_export.zip
```

脚本会生成 `data.generated.js`、`route-index.generated.js` 和 `routes/*.js`。页面会先加载轻量索引，点击某条路线时再加载该路线完整点位。

### 借助第三方 App 同步

1. Apple Watch 记录跑步。
2. iPhone 使用 Strava、HealthFit 或 RunGap 把 Apple Health 跑步同步到 Strava。
3. 在本项目运行 `sync/strava-sync.mjs` 拉取活动和路线。
4. 脚本生成 `data.generated.js`、`route-index.generated.js` 和 `routes/*.js`，检查后刷新网页。

不要把 Strava token 写进前端文件，也不要提交到公开仓库。

## 路线隐私

公开页面默认不展示原始完整路线。同步脚本会裁剪每条路线的前后若干坐标点，页面也会标注隐私半径。

## 部署到 GitHub Pages

这是纯静态项目，不需要构建步骤。推荐方式：

1. 在 GitHub 新建一个仓库，例如 `running-archive`。
2. 把本目录里的文件提交到仓库根目录。
3. 打开仓库 `Settings` -> `Pages`。
4. `Build and deployment` 选择 `Deploy from a branch`。
5. Branch 选择 `main`，目录选择 `/root`。
6. 保存后等待 GitHub 生成公开访问地址。

如果你希望访问地址是 `https://你的用户名.github.io/running-archive/`，仓库名就用 `running-archive`。如果希望是 `https://你的用户名.github.io/`，仓库名需要是 `你的用户名.github.io`。
