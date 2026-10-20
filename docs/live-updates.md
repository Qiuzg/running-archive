# 网页自动更新与轨迹快照

更新日期：2026-10-20。

## 两条更新链路

**记录与统计**：App 通过 `/api/sync/apple-workouts` 提交数据，数据库事务成功后即可被网页读取。可见网页每 15 秒请求 `/api/health` 的轻量版本标识；只有版本变化才获取跑步、比赛、路线目录和城市数据。全部请求成功且前后版本一致，才替换页面状态并重新统计。失败保留旧数据，下轮重试。返回标签页或网络恢复时立即检查，保留所选年月、列表展开数量和侧栏滚动位置。

**轨迹图片与路线集**：同步提交后，API 写入 `server/snapshot-queue/` 通知文件。systemd path 启动后台生成任务，等待 10 秒合并连续请求，然后生成路线集和全部路线缩略图。生成期间的新通知保留到下一轮；失败保留通知并在 60 秒后重试。每日北京时间 04:00 的 timer 继续兜底，服务器关机错过的定时任务在启动后补跑。

网页每分钟重新检查图片清单和路线集快照。记录可能先出现，图片生成期间显示“正在生成”。已打开旧版网页需要先载入新版一次，此后同步数据无需手动刷新。自动更新不会强制重置正在浏览的地图视角；已经打开的单条详情可重新进入以取得最新详情。

## 生成文件

| 文件 | 用途 |
| --- | --- |
| `dist/generated/atlas.json` | 超过 10km 的去重活动、统计元数据、预投影折线 |
| `dist/generated/thumbnails.json` | 路线 ID 到 SVG 文件名的映射 |
| `dist/generated/thumbnails/*.svg` | 首页与比赛共用的缩略图，按内容哈希命名 |

生成器只读数据库中已有的路线坐标，不恢复同步时裁去的起终点。使用最多 1200 个点、等比 Mercator 投影；缩略图包含起终点标记。先写完 SVG，再原子替换清单；失败保留上一份文件。旧哈希图片保留给已打开的网页使用，目前没有自动清理任务。

## 部署

标准 `server/deploy.sh` 安装以下单元：

- `running-archive-atlas.service`：运行 `python -m server.snapshot_refresh`。
- `running-archive-atlas.path`：监听非空通知目录。
- `running-archive-atlas.timer`：每日 `04:00:00 Asia/Shanghai` 运行。

API 以 `www-data` 运行，通知目录属于 `www-data:www-data`，权限 `2775`。API 只写通知，不需要静态目录写权限或执行 systemctl 的权限。生成服务负责写入 `dist/generated/`。

部署静态文件必须排除 `generated/`，防止本地旧数据覆盖服务器快照；同步 server 目录必须排除 `snapshot-queue/`，防止删除未处理通知。标准部署脚本已配置两项排除。

标准脚本仍会迁移生成数据；仅发布网页和 API 代码时，应使用有备份的定向发布，不能为更新界面而用过期本地数据重建生产数据库。

## 检查与手动更新

在服务器执行：

```bash
systemctl status running-archive-atlas.path running-archive-atlas.timer
systemctl list-timers running-archive-atlas.timer
journalctl -u running-archive-atlas.service -n 50 --no-pager
systemctl start running-archive-atlas.service
```

service 为 oneshot，成功后显示 inactive 属于正常情况；应检查 Result、日志和文件更新时间。生成失败先检查数据库可读性、磁盘空间、生成目录权限；通知持续堆积时同时检查 path 是否启用。同步响应成功但未生成时，查看 API 日志是否出现通知写入错误，日定时任务仍会兜底。

本地生成：

```bash
python3 -m server.build_atlas --output assets/generated/atlas.json
python3 -m server.build_thumbnails --output assets/generated/thumbnails.json
```

`assets/generated/`、队列、SQLite 数据库和部署备份都不提交 Git。`.env.local` 可通过 `RUNNING_API_TARGET` 指定本地 API 地址；默认使用 8000 端口。

## 验证

```bash
npm run test:web
python3 -m unittest discover -s tests -p 'test_*.py'
npm run build
bash -n server/deploy.sh
```

测试覆盖统计口径、版本不变时避免重复拉取、更新失败保留原状态、请求合并、生成期间新通知不丢失、失败保留通知、原子快照写入和等比轨迹投影。生产验证使用真实数据库和只触发生成的通知，不插入虚假运动记录。
