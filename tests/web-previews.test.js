import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureRoutePreviews } from '../src/preview-loader.js';
import { store, loadMoreRoutes, setRouteFilter } from '../src/state.js';
import { projectRoutePoints } from '../src/utils.js';

test('只加载当前 20 条轨迹，后续批次不重复下载已加载路线', async () => {
  const original = global.fetch;
  const calls = [];
  try {
    store.routes = Array.from({length:65}, (_,i) => ({id:`page-${i}`,preview_coordinates:[]}));
    global.fetch = async url => {
      const query = new URL(url, 'http://test').searchParams;
      const ids = query.getAll('route_ids');
      assert.equal(query.get('preview_points'), '1200');
      assert.ok(ids.length<=20);
      calls.push(ids);
      return Response.json(ids.map(id=>({id,preview_coordinates:[[118,32],[119,33]]})));
    };
    store.routeVisibleCount = 20;
    await ensureRoutePreviews(store.routes.slice(0,store.routeVisibleCount).map(r=>r.id));
    assert.equal(calls.length,1);
    assert.equal(store.routes.filter(r=>r.preview_loaded).length,20);
    loadMoreRoutes();
    await ensureRoutePreviews(store.routes.slice(0,store.routeVisibleCount).map(r=>r.id));
    assert.equal(calls.length,2);
    assert.equal(store.routes.filter(r=>r.preview_loaded).length,40);
    setRouteFilter('race'); assert.equal(store.routeVisibleCount,20);
  } finally { global.fetch = original; }
});

test('轨迹批次最多并发两次，单批最多 20 条', async () => {
  const original = global.fetch;
  let active=0,maxActive=0;
  try {
    store.routes=Array.from({length:45},(_,i)=>({id:`concurrent-${i}`}));
    global.fetch = async url => {
      const ids=new URL(url,'http://test').searchParams.getAll('route_ids');
      assert.ok(ids.length<=20);
      active++;maxActive=Math.max(maxActive,active);
      await new Promise(resolve=>setTimeout(resolve,2));active--;
      return Response.json(ids.map(id=>({id,preview_coordinates:[]})));
    };
    await ensureRoutePreviews(store.routes.map(r=>r.id));
    assert.equal(maxActive,2);
    assert.equal(store.routes.filter(r=>r.preview_loaded).length,45);
  } finally { global.fetch=original; }
});

test('失败轨迹不会无限自动重试，可以单独手动重试', async () => {
  const original=global.fetch;let calls=0;
  try {
    store.routes=[{id:'retry-preview'}];
    global.fetch=async()=>{calls++;return new Response('',{status:503});};
    await ensureRoutePreviews(['retry-preview']);
    await ensureRoutePreviews(['retry-preview']);
    assert.equal(calls,1);assert.equal(store.routes[0].preview_error,true);
    global.fetch=async()=>{calls++;return Response.json([{id:'retry-preview',preview_coordinates:[[1,2],[2,3]]}]);};
    await ensureRoutePreviews(['retry-preview'],{retry:true});
    assert.equal(calls,2);assert.equal(store.routes[0].preview_loaded,true);
    assert.equal(store.routes[0].preview_error,false);
  } finally {global.fetch=original;}
});

test('SVG 等比投影保留纵向、横向及静止路线，避免退化成一点', () => {
  const vertical=projectRoutePoints([[118,32],[118,32.01]],180,140,14);
  assert.equal(vertical[0].x,vertical[1].x);
  assert.ok(Math.abs(vertical[0].y-vertical[1].y)>100);
  const horizontal=projectRoutePoints([[118,32],[118.01,32]],180,140,14);
  assert.equal(horizontal[0].y,horizontal[1].y);
  assert.ok(Math.abs(horizontal[0].x-horizontal[1].x)>140);
  assert.deepEqual(projectRoutePoints([[118,32],[118,32]],180,140,14),[{x:90,y:70},{x:90,y:70}]);
});
