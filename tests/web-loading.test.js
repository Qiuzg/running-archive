import test from 'node:test';
import assert from 'node:assert/strict';
import {fetchRaces, fetchRoute} from '../src/api.js';
import {loadData} from '../src/data-loader.js';
import {store} from '../src/state.js';
test('列表 404、空响应和错误结构都视为失败；真实空数组是成功', async () => {
  const original = global.fetch;
  try {
    for (const response of [new Response('',{status:404}),new Response(null,{status:204}),Response.json({error:'invalid'})]) {
      global.fetch = async () => response;
      await assert.rejects(fetchRaces());
    }
    global.fetch = async () => Response.json([]); assert.deepEqual(await fetchRaces(),[]);
    global.fetch = async () => new Response('',{status:404}); assert.equal(await fetchRoute('missing'),null);
  } finally {global.fetch = original;}
});
test('部分失败可重试，仅请求失败资源且保留已成功数据', async () => {
  const original = global.fetch, originalError = console.error;
  const requests = [];
  try {
    console.error = () => {};
    store.dataStatus = {};
    global.fetch = async url => { requests.push(url); return url.endsWith('/runs') ? new Response('',{status:503}) : Response.json([]); };
    await loadData();
    assert.equal(store.dataStatus.races,'ready'); assert.equal(store.dataStatus.runs,'error');
    assert.equal(store.dataLoading,false);
    requests.length = 0;
    global.fetch = async url => {requests.push(url); return Response.json([{id:'run',date:'2024-01-01',distance_km:5}]);};
    await loadData();
    assert.deepEqual(requests,['/api/runs']); assert.equal(store.dataStatus.runs,'ready'); assert.equal(store.activityItems.length,1);
  } finally { global.fetch = original; console.error = originalError; }
});

test('较慢的城市边界请求不阻塞已到达的跑步记录', async () => {
  const original = global.fetch;
  let finishCities;
  const cities = new Promise(resolve => { finishCities = resolve; });
  try {
    store.dataStatus = {};
    global.fetch = async url => url.endsWith('/cities') ? cities : Response.json([]);
    const progress = [];
    const pending = loadData({onProgress: key => progress.push(key)});
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(store.dataStatus.races, 'ready');
    assert.equal(store.dataStatus.routes, 'ready');
    assert.equal(store.dataStatus.runs, 'ready');
    assert.equal(store.dataLoading, true);
    assert.deepEqual(new Set(progress), new Set(['races', 'routes', 'runs']));
    finishCities(Response.json([]));
    await pending;
    assert.equal(store.dataStatus.cityBoundaries, 'ready');
    assert.equal(store.dataLoading, false);
  } finally { global.fetch = original; }
});

test('地图和图表请求同一路线详情时只发送一次请求', async () => {
  const original = global.fetch;
  let calls = 0, resolveRequest;
  try {
    global.fetch = () => { calls++; return new Promise(resolve => { resolveRequest = resolve; }); };
    const map = fetchRoute('same-route'), charts = fetchRoute('same-route');
    assert.equal(calls, 1);
    resolveRequest(Response.json({id: 'same-route', preview_coordinates: [[118,32]]}));
    assert.deepEqual(await map, await charts);
  } finally { global.fetch = original; }
});
