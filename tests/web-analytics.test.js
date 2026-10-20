import test from 'node:test';
import assert from 'node:assert/strict';
import {yearReview, monthCalendar, pbHistory, durationSeconds, validDate, filterRoutes} from '../src/analytics.js';
import {store, rebuildDerivedData} from '../src/state.js';
const run = (date, distance_km, duration = '00:25:00', extra = {}) => ({date, distance_km, duration, ...extra});
test('同期比较只取相同日期范围，闰日对齐，未来记录不参与', () => {
  const result = yearReview([run('2024-02-29',10),run('2024-03-01',100),run('2023-02-28',5),run('2023-03-01',100)],2024,'2024-02-29');
  assert.equal(result.summary.km,10); assert.equal(result.baseline.km,5); assert.equal(result.change,100);
  assert.equal(result.previousEnd,'2023-02-28');
  assert.equal(yearReview([],2024,'2024-02-29').change,null);
});
test('过去年度比较全年，不按今天月份截断', () => {
  const result = yearReview([run('2023-12-31',10),run('2022-12-31',20)],2023,'2024-02-29');
  assert.equal(result.change,-50); assert.equal(result.monthly[11],10);
});
test('日历周一开始、支持闰年和同日多次跑步', () => {
  const calendar = monthCalendar([run('2024-02-29',5),run('2024-02-29',6)],2024,1);
  assert.equal(calendar.offset,3); assert.equal(calendar.days.length,29);
  assert.equal(calendar.days[28].km,11); assert.equal(calendar.days[28].count,2);
  assert.equal(validDate('2023-02-29'),false);
});
test('PB 使用实际用时，排除过短过长、无效和未来记录，仅保留严格提升', () => {
  const items = [run('2024-01-01',5),run('2024-01-02',5,'00:25:00'),run('2024-01-03',5.1,'00:24:00'),run('2024-01-04',4.99,'00:20:00'),run('2024-01-05',5.2,'00:19:00'),run('2024-01-06',5,'00:00:00'),run('2025-01-01',5,'00:10:00')];
  const history = pbHistory(items,5,'2024-12-31');
  assert.equal(history.length,2); assert.equal(history[1].seconds,1440); assert.equal(history[1].improvement,60);
  assert.equal(durationSeconds('25:00'),1500); assert.equal(durationSeconds('1:99:00'),null);
  assert.equal(durationSeconds('NaN'),null); assert.equal(durationSeconds('0:00'),null);
});
test('路线距离分类保留短跑，日常与长距离互不重叠', () => {
  const routes = [{id:'a',city:'上海',distance_km:3},{id:'b',city:'北京',distance_km:20}];
  const items = [run('2024-02-01',3,'20:00',{route_id:'a',name:'晨跑',source:'run'}),run('2024-02-02',20,'2:00:00',{route_id:'b',source:'run'})];
  assert.deepEqual(filterRoutes(items,routes,{kind:'middle'}).map(i => i.route_id),['a']);
  assert.deepEqual(filterRoutes(items,routes,{kind:'long'}).map(i => i.route_id),['b']);
});
test('比赛和训练有相同源记录或路线时不会重复计入', () => {
  store.races = [run('2024-01-01',42,'3:00:00',{id:'race-a',source_run_id:'a',route_id:'route-a'})];
  store.runs = [run('2024-01-01',42,'3:00:00',{id:'a',route_id:'route-a'}),run('2024-01-02',5,'30:00',{id:'b'})];
  store.routes = []; rebuildDerivedData();
  assert.equal(store.activityItems.length,2);
});
