import { store } from '../state.js';
import { yearReview, monthCalendar, pbHistory, PB_DISTANCES, totals, distance, dateKey, escapeHtml as esc } from '../analytics.js';
import { navigate } from '../ui/router.js';

const km = value => value.toLocaleString('zh-CN', {maximumFractionDigits: 1});
const duration = seconds => `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds % 3600 / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
const routeLink = (item, label) => item.route_id && store.routes.some(r => r.id === item.route_id)
  ? `<a href="#/route/${encodeURIComponent(item.route_id)}">${esc(label)} <span aria-hidden="true">↗</span></a>` : esc(label);

export function renderStatsPanel(container) {
  const year = store.selectedStatsYear || new Date().getFullYear();
  const today = dateKey();
  const review = yearReview(store.activityItems, year, today);
  const {summary, baseline, change} = review;
  const currentYear = Number(today.slice(0,4));
  const years = [...new Set([currentYear, year, ...store.availableYears])].sort((a,b) => b-a);
  const latest = review.current[0];
  const month = store.selectedStatsMonth ?? (year === currentYear ? new Date().getMonth() : latest ? Number(latest.date.slice(5,7))-1 : 0);
  const calendar = monthCalendar(review.current, year, month);
  const monthTotals = totals(calendar.records);
  const records = calendar.records.filter(i => !store.selectedStatsDay || Number(i.date.slice(8)) === store.selectedStatsDay).sort((a,b) => b.date.localeCompare(a.date));
  const max = Math.max(1, ...review.monthly, ...review.previousMonthly);
  const histories = PB_DISTANCES.map(pb => pbHistory(store.activityItems, pb.km, today));
  const history = histories[store.selectedPB];
  const changeText = change === null ? '暂无可比基线' : `${change >= 0 ? '+' : ''}${change.toFixed(1)}%`;
  const period = year === currentYear ? `截至 ${Number(today.slice(5,7))} 月 ${Number(today.slice(8))} 日` : '全年';
  container.innerHTML = `<div class="review-heading"><div><p class="review-kicker">YOUR YEAR, IN MOTION</p><h2>${year}，每一步都算数。</h2><p>从全年节奏，到每一次出发。</p></div><label class="review-year">回顾年份<select aria-label="回顾年份">${years.map(y => `<option ${year === y ? 'selected' : ''}>${y}</option>`).join('')}</select></label></div>
    <div class="review-kpis">
      <article class="review-card review-kpi review-kpi--primary"><span>${year} 年累计里程</span><strong>${km(summary.km)} <small>km</small></strong><p>${period} · ${summary.count} 次跑步</p></article>
      <article class="review-card review-kpi"><span>较 ${year-1} 年${year === currentYear ? '同期' : '全年'}</span><strong>${changeText}</strong><p>${year > currentYear ? '所选年份尚未开始' : `${year-1} 年 ${baseline.count ? km(baseline.km)+' km' : '没有已导入记录'} · ${period}`}</p></article>
      <article class="review-card review-kpi"><span>跑步天数</span><strong>${summary.days} <small>天</small></strong><p>同一天多次跑步计为一天</p></article>
      <article class="review-card review-kpi"><span>最长的一次</span><strong>${km(summary.longest)} <small>km</small></strong><p>本年度已记录的单次距离</p></article>
    </div>
    <section class="review-card review-chart" aria-labelledby="month-chart-title"><div class="review-section-head"><div><p class="review-kicker">01 / THE RHYTHM</p><h3 id="month-chart-title">一年里的跑步节奏</h3></div><p class="review-legend"><i></i>${year}<i></i>${year-1}${year === currentYear ? ' 同期' : ''} <span>· 点击月份查看明细</span></p></div>
      <div class="review-bars">${review.monthly.map((value, i) => `<button type="button" data-month="${i}" aria-pressed="${i === month}" aria-label="${i+1} 月，${year} 年 ${km(value)} 公里，${year-1} 年 ${km(review.previousMonthly[i])} 公里" title="${year}: ${km(value)} km / ${year-1}: ${km(review.previousMonthly[i])} km"><span class="review-bar-value">${value ? km(value) : '—'}</span><span class="review-bar-track"><i style="height:${review.previousMonthly[i]/max*100}%"></i><b style="height:${value/max*100}%"></b></span><span>${i+1} 月</span></button>`).join('')}</div>
    </section>
    <section class="review-card review-month" aria-labelledby="month-review-title"><div class="review-section-head"><div><p class="review-kicker">02 / THE EVERYDAY</p><h3 id="month-review-title">${month+1} 月回顾 <small>${km(monthTotals.km)} km · ${monthTotals.count} 次 · ${monthTotals.days} 天</small></h3></div><button type="button" data-clear-day ${store.selectedStatsDay ? '' : 'hidden'}>查看整月</button></div>
      <div class="review-month-grid"><div><div class="review-calendar" aria-label="${year} 年 ${month+1} 月跑步日历">${['一','二','三','四','五','六','日'].map(d=>`<span class="review-weekday">${d}</span>`).join('')}${'<span></span>'.repeat(calendar.offset)}${calendar.days.map((day,i) => `<button type="button" data-day="${i+1}" ${day.date > today ? 'disabled' : ''} class="${day.count ? 'has-run' : ''}" aria-pressed="${store.selectedStatsDay === i+1}" aria-label="${month+1} 月 ${i+1} 日，${day.count} 次跑步，${km(day.km)} 公里"><span>${i+1}</span><small>${day.count ? km(day.km) : '·'}</small></button>`).join('')}</div><p class="review-note">日历显示每日累计公里数，点击日期查看记录。</p></div>
      <div class="review-records"><h4>${store.selectedStatsDay ? `${month+1} 月 ${store.selectedStatsDay} 日` : '本月跑步'} <span>${records.length} 条记录</span></h4>${records.length ? `<div class="review-record-list">${records.map(item => `<article><div><small>${esc(item.date)}${item.source === 'race' ? ' · 比赛' : ''}</small><strong>${routeLink(item,item.name || '跑步')}</strong></div><div><strong>${km(distance(item))} <small>km</small></strong><small>${esc(item.finish_time || item.duration || '用时未记录')}</small></div></article>`).join('')}</div>` : '<p class="review-empty">这个时间范围还没有跑步记录。</p>'}</div></div>
    </section>
    <section class="review-card review-pb" aria-labelledby="pb-title"><div class="review-section-head"><div><p class="review-kicker">03 / PERSONAL MILESTONES</p><h3 id="pb-title">那些更快的时刻</h3></div><span class="review-note">全部年份 · 整次活动 PB</span></div>
      <div class="review-pb-grid">${PB_DISTANCES.map((pb,i) => {const best = histories[i].at(-1); return `<button type="button" data-pb="${i}" aria-pressed="${store.selectedPB===i}"><span>${pb.label}</span><strong>${best ? duration(best.seconds) : '—'}</strong><small>${best ? esc(best.date) : '暂无符合范围的记录'}</small></button>`;}).join('')}</div>
      <ol class="review-milestones">${[...history].reverse().map(item => `<li><time>${esc(item.date)}</time><div><strong>${duration(item.seconds)}</strong><span>${routeLink(item,item.name || '跑步')} · ${km(distance(item))} km</span></div><small>${item.improvement === null ? '首次记录' : `快了 ${duration(item.improvement)}`}</small></li>`).join('') || '<li>这个距离还没有可展示的里程碑。</li>'}</ol>
      <details class="review-method"><summary>PB 是如何计算的？</summary><p>筛选距离达到目标、且不超过目标 3% 的活动（5–5.15、10–10.3、21.0975–21.7304、42.195–43.4609 km），比较整次活动的原始用时。只展示严格变快的记录；无有效用时的活动不参与。相同日期按用时从快到慢排列。它不等同于赛会官方 PB，也不代表跑步中某一段的最快成绩，不进行距离折算。</p></details>
    </section>
    <p class="review-footnote">统计基于已导入的比赛与训练，排除未来日期。${year === currentYear ? `同期比较范围为两年的 1 月 1 日至 ${today.slice(5).replace('-', ' 月 ')} 日（闰日按去年月底对齐）。` : '历史年份按全年比较。'}未同步的日期不代表没有跑步。</p>`;
  const goMonth = (nextMonth, day) => navigate(`/stats/${year}/${nextMonth+1}${day ? '/'+day : ''}`);
  container.querySelector('.review-year select').addEventListener('change', event => navigate(`/stats/${event.target.value}`));
  container.querySelectorAll('[data-month]').forEach(button => button.addEventListener('click', () => goMonth(Number(button.dataset.month))));
  container.querySelectorAll('[data-day]').forEach(button => button.addEventListener('click', () => goMonth(month, Number(button.dataset.day))));
  container.querySelector('[data-clear-day]').addEventListener('click', () => goMonth(month));
  container.querySelectorAll('[data-pb]').forEach(button => button.addEventListener('click', () => {
    store.selectedPB = Number(button.dataset.pb);
    renderStatsPanel(container);
    container.querySelector(`[data-pb="${store.selectedPB}"]`).focus({preventScroll: true});
  }));
}
