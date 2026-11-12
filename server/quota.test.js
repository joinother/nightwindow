'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { UpstreamQuota, dayAt } = require('./quota');

function fixture(context) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'weather-quota-'));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, 'usage.json');
}

test('daily budget persists across restart and resets at Shanghai midnight', (context) => {
  const filename = fixture(context);
  let now = Date.parse('2026-11-12T15:59:59Z');
  const options = { daily: 2, now: () => now };
  const first = new UpstreamQuota(filename, options);
  assert.equal(first.reserve('24h'), true);
  const second = new UpstreamQuota(filename, options);
  assert.equal(second.reserve('168h'), true);
  assert.equal(second.reserve('24h'), false);
  assert.equal(second.snapshot().dayCalls, 2);
  assert.equal(second.snapshot().reason, 'daily_budget');
  now += 1000;
  assert.equal(dayAt(now), '2026-11-13');
  assert.equal(second.snapshot().dayCalls, 0);
  assert.equal(JSON.parse(fs.readFileSync(filename)).dayCalls, 0);
  assert.equal(JSON.parse(fs.readFileSync(filename)).day, '2026-11-13');
  assert.equal(second.reserve('24h'), true);
  assert.equal(second.snapshot().monthCalls, 3);
});

test('hourly and minute limits survive reload; provider backoff is persistent', (context) => {
  const filename = fixture(context);
  let now = Date.now();
  const options = { minute: 1, hourly: 2, now: () => now };
  let quota = new UpstreamQuota(filename, options);
  assert.equal(quota.reserve('24h'), true);
  quota = new UpstreamQuota(filename, options);
  assert.equal(quota.reserve('168h'), false);
  assert.equal(quota.reason, 'minute_budget');
  now += 60001;
  assert.equal(quota.reserve('168h'), true);
  now += 60001;
  assert.equal(quota.reserve('24h'), false);
  assert.equal(quota.reason, 'hourly_budget');
  now += 3600001;
  quota.backoff('120');
  quota = new UpstreamQuota(filename, options);
  assert.equal(quota.reserve('24h'), false);
  assert.equal(quota.reason, 'upstream_cooldown');
  now += 120001;
  assert.equal(quota.reserve('24h'), true);
});

test('legacy counts are retained and migration is marked, not silently reset', (context) => {
  const filename = fixture(context);
  fs.writeFileSync(filename, JSON.stringify({ day: '2026-11-12', dayCalls: 1659,
    month: '2026-11', monthCalls: 4238 }));
  const quota = new UpstreamQuota(filename, { daily: 1659, now: () => Date.parse('2026-11-12T11:00Z') });
  assert.equal(quota.reserve('24h'), false);
  assert.equal(quota.snapshot().transitionDay, '2026-11-12');
  assert.equal(quota.snapshot().dayCalls, 1659);
  assert.equal(JSON.parse(fs.readFileSync(filename)).timezone, 'Asia/Shanghai');
});

test('corrupt storage and failed writes cannot permit upstream work', (context) => {
  const filename = fixture(context);
  fs.writeFileSync(filename, '{bad');
  assert.throws(() => new UpstreamQuota(filename));
  fs.unlinkSync(filename);
  const quota = new UpstreamQuota(filename);
  context.mock.method(fs, 'renameSync', () => { throw new Error('disk full'); });
  assert.equal(quota.reserve('24h'), false);
  assert.equal(quota.reason, 'budget_storage_unavailable');
});
