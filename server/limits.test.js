'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ExpiringCache, createRateLimiter, parseTrustedProxy, clientIp,
  readNumber, readCoordinates, createUpstreamScheduler } = require('./limits');

test('coordinates reject missing, empty, duplicate, nonfinite and out-of-range values, but accept zero', () => {
  for (const query of ['lat=0', 'lon=0', 'lat=&lon=0', 'lat=%20&lon=0',
    'lat=NaN&lon=0', 'lat=Infinity&lon=0', 'lat=0&lon=181', 'lat=-86&lon=0',
    'lat=0&lon=-181', 'lat=0&lon=1e999', 'lat=0&lat=1&lon=0', 'lat=0x10&lon=0']) {
    assert.throws(() => readCoordinates(new URLSearchParams(query)), /bad lat\/lon/, query);
  }
  assert.deepEqual(readCoordinates(new URLSearchParams('lat=0&lon=0')), { lat: 0, lon: 0 });
  assert.deepEqual(readCoordinates(new URLSearchParams('lat=-85&lon=180')), { lat: -85, lon: 180 });
  assert.deepEqual(readCoordinates(new URLSearchParams('lat=85&lon=-180')), { lat: 85, lon: -180 });
});

test('grid defaults apply only to omitted parameters; dimensions must be integers', () => {
  const dimension = (query) => readNumber(new URLSearchParams(query), 'n', 3, 9, 7, true);
  const span = (query) => readNumber(new URLSearchParams(query), 'span', 100, 5000, 150);
  assert.equal(dimension(''), 7);
  assert.equal(span(''), 150);
  for (const value of ['', '0', '2', '10', '3.5', 'NaN', 'Infinity', '1e999']) {
    assert.throws(() => dimension('n=' + value), /bad n/);
  }
  for (const value of ['', '0', '99', '5001', 'NaN', 'Infinity']) {
    assert.throws(() => span('span=' + value), /bad span/);
  }
  assert.equal(dimension('n=3'), 3);
  assert.equal(dimension('n=9'), 9);
  assert.equal(span('span=100.5'), 100.5);
  assert.equal(span('span=5000'), 5000);
});

test('XFF requires explicitly trusted loopback, a single IP and canonical identity', () => {
  const request = (peer, forwarded) => ({ socket: { remoteAddress: peer }, headers: { 'x-forwarded-for': forwarded } });
  const trusted = parseTrustedProxy('127.0.0.1');
  assert.equal(parseTrustedProxy(), null);
  assert.throws(() => parseTrustedProxy('0.0.0.0'), /NW_TRUSTED_PROXY/);
  assert.throws(() => parseTrustedProxy('192.0.2.1'), /NW_TRUSTED_PROXY/);
  assert.equal(clientIp(request('127.0.0.1', '192.0.2.1'), null), '127.0.0.1');
  assert.equal(clientIp(request('192.0.2.2', '192.0.2.1'), trusted), '192.0.2.2');
  assert.equal(clientIp(request('127.0.0.1', '192.0.2.1'), trusted), '192.0.2.1');
  assert.equal(clientIp(request('::ffff:127.0.0.1', '::ffff:192.0.2.1'), trusted), '192.0.2.1');
  assert.equal(clientIp(request('::1', '2001:0DB8:0:0:0:0:0:1'), parseTrustedProxy('::1')), '2001:db8::1');
  for (const header of ['192.0.2.1, 192.0.2.2', 'invalid', '', ['192.0.2.1'], 'fe80::1%lo0']) {
    assert.equal(clientIp(request('127.0.0.1', header), trusted), '127.0.0.1');
  }
});

test('negative cache evicts within its cap and expires at TTL', () => {
  let now = 0;
  const cache = new ExpiringCache(2, 10, true, () => now);
  cache.set('first', true);
  cache.set('second', true);
  cache.set('third', true);
  assert.equal(cache.get('first'), undefined);
  assert.equal(cache.get('third'), true);
  assert.equal(cache.entries.size, 2);
  now = 10;
  cache.set('fourth', true);
  assert.equal(cache.entries.size, 1);
  assert.equal(cache.get('second'), undefined);
  now = 20;
  assert.equal(cache.get('fourth'), undefined);
});

test('IP cap denies new identities without resetting an active rate limit, and recovers after TTL', () => {
  let now = 0;
  const allow = createRateLimiter(2, () => now);
  for (let attempt = 0; attempt < 120; attempt++) assert.equal(allow('first'), true);
  assert.equal(allow('first'), false);
  assert.equal(allow('second'), true);
  assert.equal(allow('third'), false);
  assert.equal(allow('first'), false);
  now = 3600000;
  assert.equal(allow('third'), true);
  assert.equal(allow('first'), true);
});

test('global scheduler coalesces active and queued keys, bounds work and releases failed slots', async () => {
  const run = createUpstreamScheduler(1, 1);
  const started = [];
  let release;
  const first = run('first', () => {
    started.push('first');
    return new Promise((resolve) => { release = resolve; });
  });
  const second = run('second', () => { started.push('second'); throw new Error('upstream failed'); });
  const failure = assert.rejects(second, /upstream failed/);
  assert.equal(run('first', () => assert.fail('duplicate active work')), first);
  assert.equal(run('second', () => assert.fail('duplicate queued work')), second);
  assert.equal(await run('overflow', () => assert.fail('queue overflow work')), null);
  assert.deepEqual(started, ['first']);
  release('done');
  assert.equal(await first, 'done');
  await failure;
  assert.deepEqual(started, ['first', 'second']);
  assert.equal(await run('second', () => 'retry'), 'retry');
});
