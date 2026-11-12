'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

test('HTTP contracts and upstream protection with mocked weather provider', async (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'nightwindow-test-'));
  const previousEnv = { NW_CACHE_FILE: process.env.NW_CACHE_FILE, NW_TRUSTED_PROXY: process.env.NW_TRUSTED_PROXY,
    NW_USAGE_FILE: process.env.NW_USAGE_FILE };
  process.env.NW_CACHE_FILE = path.join(directory, 'cache.json');
  process.env.NW_USAGE_FILE = path.join(directory, 'usage.json');
  process.env.NW_TRUSTED_PROXY = '';
  const { server } = require('./server');
  const calls = [];
  let active = 0;
  let peak = 0;
  let fail = false;
  context.mock.method(globalThis, 'fetch', async (address) => {
    const url = new URL(address);
    assert.match(url.pathname, /^\/v7\/weather\/(24|168)h$/);
    const [longitude, latitude] = url.searchParams.get('location').split(',').map(Number);
    assert.ok(Math.abs(latitude) <= 85 && Math.abs(longitude) <= 180);
    calls.push(url);
    active++;
    peak = Math.max(peak, active);
    await delay(5);
    if (fail) {
      return { ok: false, status: 400, body: { cancel: async () => {
        await delay(5);
        active--;
      } } };
    }
    return { ok: true, json: async () => {
      await delay(5);
      active--;
      return { code: '200', hourly: [{ fxTime: '2026-11-11T20:00+08:00', cloud: '20',
        windSpeed: '10', wind360: '90', humidity: '60', precip: '0', pressure: '1000', temp: '12', dew: '4' }] };
    } };
  });
  context.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
    for (const [name, value] of Object.entries(previousEnv)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const request = (route, headers = {}) => new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port: server.address().port, path: route, headers }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(body) }));
      response.on('error', reject);
    }).on('error', reject);
  });

  await context.test('invalid requests return 400 before any upstream work', async () => {
    for (const route of ['/v1/wx', '/v1/wx?lat=&lon=0', '/v1/week?lat=0&lon=181',
      '/v1/grid?lat=0&lon=0&n=3.5', '/v1/grid?lat=0&lon=0&span=NaN',
      '/v1/grid?lat=0&lon=0&n=0', '/v1/grid?lat=0&lon=0&span=0']) {
      const result = await request(route);
      assert.equal(result.status, 400, route);
      assert.equal(result.body.ok, false);
      assert.equal(typeof result.body.error, 'string');
    }
    assert.equal(calls.length, 0);
  });

  await context.test('zero coordinates work and same rounded key is fetched only once', async () => {
    const results = await Promise.all(Array.from({ length: 8 }, (_, index) => request('/v1/wx?lat=0&lon=' + index / 100)));
    assert.equal(calls.length, 1);
    const health = await request('/healthz');
    assert.equal(health.body.qw.dayCalls, 1);
    assert.equal(health.body.qw.monthCalls, 1);
    for (const result of results) {
      assert.equal(result.status, 200);
      assert.equal(result.body.ok, true);
      assert.deepEqual(Object.keys(result.body).sort(), ['ok', 'oldestAge', 'points']);
      assert.deepEqual(Object.keys(result.body.points[0]).sort(), ['age', 'hours', 'lat', 'lon']);
      assert.deepEqual(result.body.points[0].hours[0], { t: '2026-11-11T20:00+08:00', c: 20,
        ws: 10, wd: 90, h: 60, p: 0, pr: 1000, tp: 12, dw: 4 });
    }
    await request('/v1/wx?lat=0&lon=0');
    assert.equal(calls.length, 1);
  });

  await context.test('24h and 168h share one global concurrency limit but not their cache keys', async () => {
    calls.length = 0;
    peak = 0;
    const routes = Array.from({ length: 12 }, (_, index) => '/v1/' + (index % 2 ? 'week' : 'wx') + '?lat=10&lon=' + index);
    routes.push('/v1/week?lat=10&lon=0', '/v1/week?lat=10&lon=0');
    const results = await Promise.all(routes.map((route) => request(route)));
    assert.equal(calls.length, 13);
    assert.equal(peak, 6);
    assert.ok(results.every((result) => result.status === 200 && result.body.ok));
    assert.deepEqual(Object.keys(results[1].body).sort(), ['age', 'hours', 'ok']);
  });

  await context.test('edge grids preserve point count and report unsupported coordinates as null', async () => {
    calls.length = 0;
    const result = await request('/v1/grid?lat=85&lon=180&span=100&n=3');
    assert.equal(result.status, 200);
    assert.deepEqual(Object.keys(result.body).sort(), ['n', 'ok', 'okPoints', 'oldestAge', 'points', 'span', 'total']);
    assert.equal(result.body.total, 9);
    assert.equal(result.body.okPoints, 4);
    assert.equal(result.body.points.filter((point) => point.hours === null && point.age === null).length, 5);
    assert.equal(calls.length, 4);
    const dense = await request('/v1/grid?lat=85&lon=180&span=100&n=9');
    assert.equal(dense.body.total, 81);
    assert.equal(dense.body.okPoints, 25);
    for (const point of dense.body.points) {
      if (point.lat > 85 || point.lon > 180) {
        assert.equal(point.hours, null);
        assert.equal(point.age, null);
      } else {
        assert.ok(Array.isArray(point.hours));
      }
    }
  });

  await context.test('negative point cache suppresses repeated failures; week failure contract is unchanged', async () => {
    fail = true;
    calls.length = 0;
    const first = await request('/v1/wx?lat=50&lon=50');
    const second = await request('/v1/wx?lat=50&lon=50');
    assert.deepEqual(second, first);
    assert.equal(first.body.ok, false);
    assert.equal(first.body.points[0].hours, null);
    assert.equal(calls.length, 1);
    const week = await request('/v1/week?lat=50&lon=50');
    assert.deepEqual(week, { status: 200, body: { ok: false, points: [] } });
    const beforeRepeat = calls.length;
    await request('/v1/week?lat=50&lon=50');
    assert.equal(calls.length, beforeRepeat);
    assert.equal(active, 0);
    fail = false;
  });

  await context.test('default proxy policy ignores changing XFF and health remains available', async () => {
    let blocked = false;
    for (let attempt = 0; attempt <= 120; attempt++) {
      const result = await request('/v1/wx?lat=0&lon=0', { 'X-Forwarded-For': '192.0.2.' + (attempt + 1) });
      if (result.status === 429) {
        assert.deepEqual(result.body, { ok: false, error: 'rate_limited' });
        blocked = true;
        break;
      }
    }
    assert.equal(blocked, true);
    assert.equal((await request('/healthz')).status, 200);
  });
});
