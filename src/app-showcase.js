const media = `${import.meta.env.BASE_URL}app-showcase/`;
const screenshots = [
  { id: "home", file: "real-home.jpg", title: "地图里的跑步档案" },
  { id: "records", file: "real-records.jpg", title: "按年月翻看跑步记录" },
  { id: "detail", file: "real-detail.jpg", title: "10 月 18 日 · 10.64 公里" },
  { id: "analysis", file: "real-analysis.jpg", title: "近期训练分析", note: "查看近期跑量与训练变化" },
  { id: "plan", file: "real-plan.jpg", title: "训练计划入口", note: "配置模型、目标和可训练时间后，可生成计划" },
  { id: "month", file: "real-month.jpg", title: "2026 年 10 月 · 跑步回顾" },
  { id: "share", file: "real-share.jpg", title: "跑步记录的分享设置" },
  { id: "export", file: "real-export.jpg", title: "导出自己的跑步数据" },
  { id: "poster-light", file: "real-poster-light.jpg", title: "10 月浅色分享图", note: "2026 年 10 月月报 · 截至 18 日" },
  { id: "poster-dark", file: "real-poster-dark.jpg", title: "10 月深色分享图", note: "2026 年 10 月月报 · 截至 18 日" },
];

const features = {
  records: {
    index: "01 / 跑步档案", word: "ARCHIVE", title: ["记得跑了多远，", "也记得跑过哪里。"],
    description: "直接读取 Apple 健康中的跑步记录。用地图重访路线，按年月翻看训练，再进入某一次跑步的完整细节。",
    details: [["一份随身档案", "地图足迹、逐次记录和个人纪录放在一起。"], ["从总览走进细节", "查看配速、心率、海拔、步频和功率变化。"], ["打开就接着看", "本地缓存优先显示，健康数据在后台更新。"]],
    note: "档案、详情和分享可直接在手机使用，无需连接网页数据库。",
  },
  analysis: {
    index: "02 / 训练分析", word: "INSIGHT", title: ["这些变化，", "对我意味着什么？"],
    description: "把近期跑量、实际成绩和训练负荷放在一起。先解释相对自己的变化，再按需要查看计算依据。",
    details: [["与自己的平常比较", "用短期与长期负荷变化，理解最近练得更多还是更少。"], ["优先展示 Apple 心率区间", "区分运动原始记录与按当前设置重新分类的结果。"], ["数据有边界，解释也一样", "估算注明依据，缺失说明原因，不把空数据当成零。"]],
    note: "睡眠和心率作为辅助背景；公式、条件与来源可展开查看。",
  },
  plan: {
    index: "03 / 目标赛事与 AI 计划", word: "NEXT RUN", title: ["从最近的跑步，", "安排下一次出发。"],
    description: "选定要备战的赛事，结合近期训练和可训练时间生成七天计划。计划可以自己修改，再发送到 Apple Watch 自带的体能训练 App。",
    details: [["记下目标赛事", "保存比赛名称、日期、距离和目标成绩，查看倒计时与目标配速。"], ["带着比赛目标来安排", "在 AI 设置中选择已有赛事，带入日期、距离和目标成绩，结合近期状态及训练时间生成计划。"], ["改好计划，发到手表", "调整热身、跑步段、恢复和重复次数，再同步到 Apple Watch。"]],
    note: "手表同步已接入并完成模拟器检查；实际接收与运动提醒仍待真机验证。",
  },
  month: {
    index: "04 / 月度回顾", word: "PROGRESS", title: ["把日复一日，", "看成一段积累。"],
    description: "按月和按年回顾自己的跑步：累计距离、日历分布、长距离训练，以及一次次坚持留下的变化。",
    details: [["从日历找回那一天", "一天一条记录直接进入详情，多条记录先筛选查看。"], ["不同时间尺度的回顾", "月度、年度统计和长距离路线集，记录不同阶段。"], ["把积累保存下来", "生成月报、年报图片，长距离路线集也支持深浅色。"]],
    note: "回顾使用实际记录汇总；跑量与配速沿用一致的数据口径。",
  },
  share: {
    index: "05 / 图片分享", word: "STORIES", title: ["这一趟跑步，", "值得一张自己的图。"],
    description: "选一次跑步，写一句标题，把路线与数据排成一张图片。保留地图的颜色，也保留属于这次出发的记忆。",
    details: [["两种版式", "图文与竖屏，适合不同的分享场景。"], ["选自己喜欢的样子", "深浅配色、地图源、自定义标题与可选档案二维码。"], ["先看效果，再分享", "手动生成预览，保存相册或调用 iOS 系统分享。"]],
    note: "截图展示真实记录的图片设置。单次、月度和年度分享均在 App 内完成。",
  },
  export: {
    index: "06 / 数据导出", word: "YOUR DATA", title: ["自己的记录，", "也可以带走。"],
    description: "按日期选择跑步记录，在本机生成分析文件。既可以直接查看 Excel，也可以保留原始过程数据和路线。",
    details: [["一份可读的 Excel", "逐次记录、公里分段、过程指标与训练分析放在一起。"], ["需要时，保留更多细节", "完整包附原始采样 CSV 与路线 GPX。"], ["结果可以核对", "同时保留指标单位、覆盖情况、计算依据与缺失说明。"]],
    note: "文件在手机本地生成，由你选择保存或分享。",
  },
};

function selectFeature(id) {
  const feature = features[id];
  if (!feature) return;
  document.querySelectorAll("[data-feature]").forEach(button => {
    button.setAttribute("aria-pressed", String(button.dataset.feature === id));
  });
  const screenshot = screenshots.find(item => item.id === id);
  const img = document.getElementById("featureImage");
  img.src = media + screenshot.file;
  img.alt = screenshot.title;
  const preview = document.getElementById("featurePreview");
  preview.dataset.preview = id;
  preview.setAttribute("aria-label", `放大查看${screenshot.title}截图`);
  document.querySelector(".stage-word").textContent = feature.word;
  document.getElementById("featureIndex").textContent = feature.index;
  const title = document.getElementById("featureTitle");
  title.replaceChildren(document.createTextNode(feature.title[0]), document.createElement("br"), document.createTextNode(feature.title[1]));
  document.getElementById("featureDescription").textContent = feature.description;
  document.getElementById("featureFootnote").textContent = feature.note;
  document.getElementById("featureDetails").replaceChildren(...feature.details.map(([heading, text]) => {
    const li = document.createElement("li");
    const strong = document.createElement("strong");
    const span = document.createElement("span");
    strong.textContent = heading;
    span.textContent = text;
    li.append(strong, span);
    return li;
  }));
}

document.querySelectorAll("[data-feature]").forEach(button => {
  button.addEventListener("click", () => selectFeature(button.dataset.feature));
});
document.querySelectorAll("[data-select-feature]").forEach(link => {
  link.addEventListener("click", () => selectFeature(link.dataset.selectFeature));
});

const themeButton = document.getElementById("themeToggle");
function updateThemeControl() {
  const dark = document.documentElement.dataset.theme === "dark";
  const label = dark ? "切换浅色模式" : "切换深色模式";
  themeButton.setAttribute("aria-label", label);
  themeButton.title = label;
  themeButton.querySelector(".theme-toggle__icon").textContent = dark ? "🌙" : "☀️";
  themeButton.setAttribute("aria-pressed", String(dark));
  document.querySelector('meta[name="theme-color"]').content = dark ? "#151b1c" : "#f5f3ee";
}
themeButton.addEventListener("click", () => {
  const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem("theme", theme); } catch { /* Theme still works without storage. */ }
  updateThemeControl();
});
updateThemeControl();

const dialog = document.getElementById("imageDialog");
let previewIndex = 0;
function renderPreview() {
  const item = screenshots[previewIndex];
  const img = document.getElementById("dialogImage");
  img.src = media + item.file;
  img.alt = item.title;
  document.getElementById("dialogTitle").textContent = item.title;
  document.getElementById("dialogNote").textContent = item.note || "Run Log · iPhone App";
  document.getElementById("dialogCount").textContent = `${previewIndex + 1} / ${screenshots.length}`;
  document.querySelector(".dialog-image").scrollTop = 0;
}
document.addEventListener("click", event => {
  const trigger = event.target.closest("[data-preview]");
  if (!trigger) return;
  const index = screenshots.findIndex(item => item.id === trigger.dataset.preview);
  if (index < 0) return;
  previewIndex = index;
  renderPreview();
  dialog.showModal();
  document.body.classList.add("preview-open");
});
function movePreview(offset) {
  previewIndex = (previewIndex + offset + screenshots.length) % screenshots.length;
  renderPreview();
}
document.getElementById("previousPreview").addEventListener("click", () => movePreview(-1));
document.getElementById("nextPreview").addEventListener("click", () => movePreview(1));
document.getElementById("closePreview").addEventListener("click", () => dialog.close());
dialog.addEventListener("close", () => document.body.classList.remove("preview-open"));
dialog.addEventListener("click", event => {
  const bounds = dialog.getBoundingClientRect();
  if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
});
dialog.addEventListener("keydown", event => {
  if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
    event.preventDefault();
    movePreview(event.key === "ArrowRight" ? 1 : -1);
  }
});
