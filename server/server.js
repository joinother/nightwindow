'use strict';
/**
 * 今夜星 天气代理服务
 *  - 和风 Key 只在服务端，客户端拿不到
 *  - 单点 /v1/wx，多点 /v1/grid（客户端一次拿全网格，不再逐点请求）
 *  - 上游按 0.5° 取整去重 + 30 分钟缓存
 */
const http = require('http');
const { URL } = require('url');

const PORT = Number(process.env.NW_PORT || 8090);
const QW_HOST = process.env.QW_HOST || 'mn6hf38tay.re.qweatherapi.com';
const QW_KEY = process.env.QW_KEY || '';
const TTL_MS = Number(process.env.NW_TTL_MS || 30 * 60 * 1000);
const MAX_KEYS = 800;

const cache = new Map(); // key -> {ts, hours}
const ipHits = new Map(); // ip -> {ts, count}

function log(...a) { console.log(new Date().toISOString(), ...a); }

function clientIp(req) {
  const xf = req.headers['x-forwarded-for'];
  if (typeof xf === 'string' && xf.length) return xf.split(',')[0].trim();
  return req.socket.remoteAddress || 'unknown';
}

/** 简单限流：每 IP 每小时 120 次 */
function allow(ip) {
  const now = Date.now();
  let rec = ipHits.get(ip);
  if (!rec || now - rec.ts > 3600 * 1000) { rec = { ts: now, count: 0 }; ipHits.set(ip, rec); }
  rec.count++;
  return rec.count <= 120;
}

function round05(v) { return Math.round(v * 2) / 2; }

function simplify(h) {
  return {
    t: h.fxTime,
    c: Number(h.cloud),
    ws: Number(h.windSpeed),
    wd: Number(h.wind360),
    h: Number(h.humidity),
    p: Number(h.precip),
    pr: Number(h.pressure),
    tp: Number(h.temp),
    dw: Number(h.dew)
  };
}

async function fetchPoint(lat, lon) {
  const key = round05(lat) + ',' + round05(lon);
  const hit = cache.get(key);
  const now = Date.now();
  if (hit && now - hit.ts < TTL_MS) return hit.hours;

  const loc = round05(lon).toFixed(2) + ',' + round05(lat).toFixed(2);
  const url = 'https://' + QW_HOST + '/v7/weather/24h?location=' + loc + '&key=' + QW_KEY;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), 8000);
  try {
    const res = await fetch(url, { signal: ac.signal, headers: { 'Accept-Encoding': 'identity' } });
    if (!res.ok) { log('upstream http', res.status, loc); return null; }
    const body = await res.json();
    if (body.code !== '200' || !Array.isArray(body.hourly)) { log('upstream code', body.code, loc); return null; }
    const hours = body.hourly.map(simplify);
    if (cache.size > MAX_KEYS) cache.delete(cache.keys().next().value);
    cache.set(key, { ts: now, hours });
    return hours;
  } catch (e) {
    log('fetch fail', loc, e.message);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function buildGrid(lat, lon, spanKm, n) {
  const half = (n - 1) / 2;
  const dLat = spanKm / 111.0;
  const dLon = spanKm / (111.0 * Math.max(0.2, Math.cos(lat * Math.PI / 180)));
  const pts = [];
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) {
      pts.push({ lat: lat + (i - half) * dLat, lon: lon + (j - half) * dLon });
    }
  }
  return pts;
}

async function handleGrid(u) {
  const lat = Number(u.searchParams.get('lat'));
  const lon = Number(u.searchParams.get('lon'));
  const span = Math.min(5000, Math.max(100, Number(u.searchParams.get('span') || 150)));
  const n = Math.min(9, Math.max(3, Number(u.searchParams.get('n') || 7)));
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 85) throw new Error('bad lat/lon');

  const pts = buildGrid(lat, lon, span, n);
  // 去重：同一 0.5° 只取一次上游
  const uniq = new Map();
  for (const p of pts) uniq.set(round05(p.lat) + ',' + round05(p.lon), p);
  const keys = Array.from(uniq.keys());
  const out = new Map();

  const CONC = 6;
  for (let i = 0; i < keys.length; i += CONC) {
    const slice = keys.slice(i, i + CONC);
    await Promise.all(slice.map(async (k) => {
      const p = uniq.get(k);
      const hours = await fetchPoint(p.lat, p.lon);
      if (hours) out.set(k, hours);
    }));
  }

  const points = pts.map((p) => {
    const hours = out.get(round05(p.lat) + ',' + round05(p.lon)) || null;
    return { lat: Number(p.lat.toFixed(4)), lon: Number(p.lon.toFixed(4)), hours };
  });
  const ok = points.filter((p) => p.hours).length;
  return { ok: ok > 0, okPoints: ok, total: points.length, span, n, points };
}

async function handleWx(u) {
  const lat = Number(u.searchParams.get('lat'));
  const lon = Number(u.searchParams.get('lon'));
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 85) throw new Error('bad lat/lon');
  const hours = await fetchPoint(lat, lon);
  return { ok: !!hours, points: [{ lat, lon, hours }] };
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const ip = clientIp(req);
  const send = (code, obj) => {
    const s = JSON.stringify(obj);
    res.writeHead(code, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'Content-Length': Buffer.byteLength(s)
    });
    res.end(s);
  };

  if (u.pathname === '/healthz') return send(200, { ok: true, up: process.uptime() });
  if (!allow(ip)) return send(429, { ok: false, error: 'rate_limited' });

  try {
    if (u.pathname === '/v1/wx') return send(200, await handleWx(u));
    if (u.pathname === '/v1/grid') return send(200, await handleGrid(u));
    send(404, { ok: false, error: 'not_found' });
  } catch (e) {
    send(400, { ok: false, error: e.message });
  }
});

server.listen(PORT, '127.0.0.1', () => log('nightwindow-api listening on', PORT, 'cache keys', cache.size));
