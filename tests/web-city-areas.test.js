import test from 'node:test';
import assert from 'node:assert/strict';
import { raceCityAreas, resolveRaceCity } from '../src/city-areas.js';

const boundaries = ['宿迁', '眉山', '南京', '杭州'].map(city => ({ city, geojson: { type: 'FeatureCollection', features: [] } }));
test('宿迁城市为空、眉山被旧导入标为成都时，按赛事名匹配真实边界', () => {
  const races = [
    { name: '2026宿迁马拉松', city: '', type: 'marathon', route_id: 'suqian' },
    { name: '2026眉山仁寿半程马拉松', city: '成都', type: 'half_marathon', route_id: 'meishan' },
    { name: '2026仙林半程马拉松', city: '南京', type: 'half_marathon', route_id: 'nanjing' },
    { name: '2025南京马拉松', city: '南京市', type: 'marathon', route_id: 'nanjing' },
    { name: '2026杭州西湖半程马拉松', city: '杭州', type: 'half_marathon', route_id: 'hangzhou' },
  ];
  const routes = ['suqian', 'meishan', 'nanjing', 'hangzhou'].map(id => ({ id, preview_coordinates: [[118, 32]] }));
  const areas = raceCityAreas(races, routes, boundaries);
  assert.deepEqual([...areas.keys()], ['宿迁', '眉山', '南京', '杭州']);
  for (const area of areas.values()) assert.equal(area.boundary.city, area.city);
  assert.equal(areas.get('南京').names.length, 2);
  assert.equal(races[1].city, '成都'); // Resolving a display area does not rewrite source records.
});
test('未知赛事保留原城市，没有轨迹或非比赛的记录不生成城市区域', () => {
  assert.equal(resolveRaceCity({ name: '环湖半程马拉松', city: '无锡市' }, boundaries), '无锡');
  assert.equal(resolveRaceCity({ name: '晨跑', city: '' }, boundaries), '');
  assert.equal(raceCityAreas([{ name: '南京马拉松', type: 'marathon' }], [], boundaries).size, 0);
  assert.equal(raceCityAreas([{ name: '南京跑步', type: 'run', route_id: 'r' }], [{ id: 'r', preview_coordinates: [[118, 32]] }], boundaries).size, 0);
});
test('城市轮廓不等待路线坐标批次，轻量目录也能匹配行政边界', () => {
  const areas = raceCityAreas([{name:'2026宿迁马拉松',city:'',type:'marathon',route_id:'r'}], [{id:'r',preview_coordinates:[]}], boundaries);
  assert.equal(areas.get('宿迁').boundary.city,'宿迁');
  assert.deepEqual(areas.get('宿迁').coordinates,[]);
});
