'use strict';

const { isIP } = require('node:net');

class ExpiringCache {
  constructor(maxEntries, ttl, evict = true, now = Date.now) {
    this.maxEntries = maxEntries;
    this.ttl = ttl;
    this.evict = evict;
    this.now = now;
    this.entries = new Map();
  }

  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (this.now() >= entry.expires) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key, value) {
    const now = this.now();
    for (const [entryKey, entry] of this.entries) {
      if (now >= entry.expires) this.entries.delete(entryKey);
    }
    if (!this.entries.has(key) && this.entries.size >= this.maxEntries) {
      if (!this.evict) return false;
      this.entries.delete(this.entries.keys().next().value);
    }
    this.entries.delete(key);
    this.entries.set(key, { value, expires: now + this.ttl });
    return true;
  }
}

function createRateLimiter(maxEntries = 4096, now = Date.now) {
  const hits = new ExpiringCache(maxEntries, 3600000, false, now);
  return (ip) => {
    let record = hits.get(ip);
    if (!record) {
      record = { count: 0 };
      if (!hits.set(ip, record)) return false;
    }
    record.count++;
    return record.count <= 120;
  };
}

function normalizeIp(value) {
  if (typeof value !== 'string') return null;
  const version = isIP(value);
  if (version === 4) return value;
  if (version !== 6 || value.includes('%')) return null;
  const address = new URL('http://[' + value + ']/').hostname.slice(1, -1);
  const mapped = /^::ffff:([0-9a-f]+):([0-9a-f]+)$/.exec(address);
  if (!mapped) return address;
  const upper = parseInt(mapped[1], 16);
  const lower = parseInt(mapped[2], 16);
  return [upper >> 8, upper & 255, lower >> 8, lower & 255].join('.');
}

function parseTrustedProxy(value = '') {
  if (value === '') return null;
  const address = normalizeIp(value);
  if (address !== '127.0.0.1' && address !== '::1') {
    throw new Error('NW_TRUSTED_PROXY must be empty, 127.0.0.1 or ::1');
  }
  return address;
}

function clientIp(req, trustedProxy) {
  const peer = normalizeIp(req.socket.remoteAddress) || 'unknown';
  if (trustedProxy && peer === trustedProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    if (typeof forwarded === 'string') {
      const address = normalizeIp(forwarded.trim());
      if (address) return address;
    }
  }
  return peer;
}

function readNumber(params, name, minimum, maximum, fallback, integer = false) {
  const values = params.getAll(name);
  if (!values.length && fallback !== undefined) return fallback;
  const raw = values[0];
  const value = Number(raw);
  if (values.length !== 1 || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(raw) ||
      !Number.isFinite(value) || value < minimum || value > maximum ||
      (integer && !Number.isInteger(value))) {
    throw new Error('bad ' + name);
  }
  return value;
}

function readCoordinates(params) {
  try {
    return {
      lat: readNumber(params, 'lat', -85, 85),
      lon: readNumber(params, 'lon', -180, 180)
    };
  } catch {
    throw new Error('bad lat/lon');
  }
}

function createUpstreamScheduler(concurrency = 6, maxWaiting = 24) {
  const inflight = new Map();
  const waiting = [];
  let active = 0;

  function drain() {
    while (active < concurrency && waiting.length) {
      const entry = waiting.shift();
      active++;
      const finish = (settle, value) => {
        active--;
        inflight.delete(entry.key);
        drain();
        settle(value);
      };
      Promise.resolve().then(entry.task).then(
        (value) => finish(entry.resolve, value),
        (error) => finish(entry.reject, error)
      );
    }
  }

  return (key, task) => {
    const shared = inflight.get(key);
    if (shared) return shared.promise;
    if (inflight.size >= concurrency + maxWaiting) return Promise.resolve(null);
    const entry = { key, task };
    entry.promise = new Promise((resolve, reject) => {
      entry.resolve = resolve;
      entry.reject = reject;
    });
    inflight.set(key, entry);
    waiting.push(entry);
    drain();
    return entry.promise;
  };
}

module.exports = { ExpiringCache, createRateLimiter, parseTrustedProxy, clientIp,
  readNumber, readCoordinates, createUpstreamScheduler };
