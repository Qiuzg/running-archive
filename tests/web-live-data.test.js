import test from 'node:test';
import assert from 'node:assert/strict';
import { store } from '../src/state.js';
import { refreshLiveData } from '../src/live-data.js';
test('后台更新只发布完整数据，失败保留旧数据并重试，版本不变不重复拉取', async () => {
  const original = global.fetch;
  store.dataLoading = false;
  store.runs = [{id:'old',date:'2026-01-01'}];
  let fail = true, calls = [], revision = 'v1';
  global.fetch = async url => {
    calls.push(url);
    if (url.endsWith('/health')) return Response.json({data_version:revision});
    if (url.endsWith('/runs')) return fail ? new Response('',{status:503}) : Response.json([{id:'new',date:'2026-10-19',distance_km:10}]);
    return Response.json([]);
  };
  try {
    await assert.rejects(refreshLiveData());
    assert.equal(store.runs[0].id,'old');
    fail = false;
    const pending = refreshLiveData();
    assert.equal(refreshLiveData(),pending);
    assert.equal(await pending,true);
    assert.equal(store.runs[0].id,'new');
    assert.equal(store.activityItems[0].distance_km,10);
    calls=[];
    assert.equal(await refreshLiveData(),false);
    assert.deepEqual(calls,['/api/health']);
    revision='v2';
    const fetch = global.fetch;
    global.fetch = async url => { const result = await fetch(url); if(url.endsWith('/runs')) revision='v3'; return result; };
    assert.equal(await refreshLiveData(),false);
  } finally {global.fetch=original;}
});
