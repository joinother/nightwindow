import { common } from '@kit.AbilityKit';
import { City, DayData, ScoreResult, Window } from '../data/Models';
import { DEEP_TARGETS, scoreFor, windowFor } from '../score/Score';
import { WeatherRepo } from '../weather/WeatherRepo';
import { ApiGridPoint, ApiSource } from '../weather/ApiSource';
import { CITIES } from '../../viewmodel/TonightViewModel';
import { ChinaCity, CHINA_CITIES } from './ChinaCities';

/** 网格上的一个点 */
@ObservedV2
export class GridPoint {
  @Trace lat: number = 0;
  @Trace lon: number = 0;
  @Trace bortle: number = 5;
  @Trace score: number = 0;
  @Trace ok: boolean = false;
  @Trace cloud: number = 0;
  @Trace wind: number = 0;
  @Trace name: string = '';
}

const RAD: number = Math.PI / 180.0;

function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat: number = (lat2 - lat1) * RAD;
  const dLon: number = (lon2 - lon1) * RAD;
  const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * 观星指数网格。
 *
 * 光污染用「到最近已知城市/暗夜点的距离」粗估 Bortle——这是临时方案，
 * 等 VIIRS 栅格接入后替换（文档 §6.9 / B11）。
 */
export class IndexGrid {
  /** 全国：在给定经纬度范围内铺 n×n 个采样点（用于插值成连续色场） */
  static async buildBounds(ctx: common.Context, latMin: number, latMax: number,
    lonMin: number, lonMax: number, n: number, ymd: number[]): Promise<GridPoint[]> {
    const pts: GridPoint[] = [];
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        const p: GridPoint = new GridPoint();
        p.lat = latMin + (latMax - latMin) * i / (n - 1);
        p.lon = lonMin + (lonMax - lonMin) * j / (n - 1);
        p.bortle = IndexGrid.bortleAt(p.lat, p.lon, 6);
        pts.push(p);
      }
    }
    const grid: ApiGridPoint[] = await ApiSource.grid(
      (latMin + latMax) / 2, (lonMin + lonMax) / 2,
      Math.max(100, (latMax - latMin) * 111), n);
    for (let i = 0; i < pts.length; i++) {
      const g: ApiGridPoint | null = i < grid.length ? grid[i] : null;
      if (g === null || g.day === null) {
        pts[i].ok = false;
        continue;
      }
      // 用服务端回传的坐标，避免两端算出的网格错位
      pts[i].lat = g.lat;
      pts[i].lon = g.lon;
      const r: ScoreResult = IndexGrid.scoreAt(g.day!, g.lat, g.lon, pts[i].bortle, ymd);
      pts[i].score = r.total;
      pts[i].ok = true;
    }
    return pts;
  }

  /** 按城市点逐个算分（旧路径，已由服务端网格替代） */
  static async buildNational(ctx: common.Context, ymd: number[]): Promise<GridPoint[]> {
    const pts: GridPoint[] = [];
    for (const c of CHINA_CITIES) {
      const p: GridPoint = new GridPoint();
      p.lat = c.lat;
      p.lon = c.lon;
      p.bortle = c.bortle;
      p.name = c.name;
      pts.push(p);
    }
    const CHUNK: number = 6;
    for (let s = 0; s < pts.length; s += CHUNK) {
      const slice: GridPoint[] = pts.slice(s, s + CHUNK);
      const jobs: Promise<void>[] = slice.map((p: GridPoint) => {
        return WeatherRepo.load(ctx, p.lat, p.lon, false, false).then((b) => {
          if (!b.ok) {
            p.ok = false;
            return;
          }
          const r: ScoreResult = IndexGrid.scoreAt(b.day, p.lat, p.lon, p.bortle, ymd);
          p.score = r.total;
          p.cloud = r.cloud;
          p.wind = r.wind;
          p.ok = true;
        });
      });
      await Promise.all(jobs);
    }
    return pts;
  }

  /** 把采样网格双线性插值成更密的网格，用于连续渲染 */
  static interpolate(samples: GridPoint[], n: number, outN: number): GridPoint[] {
    const out: GridPoint[] = [];
    for (let i = 0; i < outN; i++) {
      for (let j = 0; j < outN; j++) {
        const fx: number = (n - 1) * i / (outN - 1);
        const fy: number = (n - 1) * j / (outN - 1);
        const x0: number = Math.floor(fx);
        const y0: number = Math.floor(fy);
        const x1: number = Math.min(n - 1, x0 + 1);
        const y1: number = Math.min(n - 1, y0 + 1);
        const tx: number = fx - x0;
        const ty: number = fy - y0;
        const p00: GridPoint = samples[x0 * n + y0];
        const p10: GridPoint = samples[x1 * n + y0];
        const p01: GridPoint = samples[x0 * n + y1];
        const p11: GridPoint = samples[x1 * n + y1];
        const top: number = p00.score * (1 - tx) + p10.score * tx;
        const bot: number = p01.score * (1 - tx) + p11.score * tx;
        const g: GridPoint = new GridPoint();
        g.score = top * (1 - ty) + bot * ty;
        g.lat = p00.lat + (p10.lat - p00.lat) * tx + ((p01.lat - p00.lat) * ty);
        g.lon = p00.lon + (p10.lon - p00.lon) * tx + ((p01.lon - p00.lon) * ty);
        g.ok = p00.ok && p10.ok && p01.ok && p11.ok;
        out.push(g);
      }
    }
    return out;
  }

  /** 距离 → Bortle 的粗估阶梯 */
  private static bortleAt(lat: number, lon: number, fallback: number): number {
    let minD: number = 1e9;
    for (const c of CITIES) {
      const d: number = distanceKm(lat, lon, c.lat, c.lon);
      if (d < minD) minD = d;
    }
    if (minD < 12) return 9;
    if (minD < 25) return 8;
    if (minD < 45) return 7;
    if (minD < 70) return 6;
    if (minD < 100) return 5;
    if (minD < 150) return 4;
    return Math.max(2, fallback - 1);
  }

  /** 一个点的今夜分数（复用正式评分，不是另一套公式） */
  private static scoreAt(day: DayData, lat: number, lon: number, bortle: number,
    ymd: number[]): ScoreResult {
    const city: City = new City('', lat, lon, bortle);
    let best: ScoreResult | null = null;
    for (const t of DEEP_TARGETS) {
      const w: Window | null = windowFor(day, city, t, ymd);
      const r: ScoreResult = scoreFor(day, city, t, w, ymd);
      if (best === null || r.total > best.total) best = r;
    }
    return best === null ? new ScoreResult() : best;
  }

  /**
   * 建 n×n 网格并逐点算分。
   * 并发 4 个请求，避免把和风的免费配额一次打光。
   */
  static async build(ctx: common.Context, centerLat: number, centerLon: number,
    n: number, spacingKm: number, ymd: number[], fallbackBortle: number): Promise<GridPoint[]> {
    const half: number = (n - 1) / 2;
    const dLat: number = spacingKm / 111.0;
    const dLon: number = spacingKm / (111.0 * Math.cos(centerLat * RAD));

    const pts: GridPoint[] = [];
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        const p: GridPoint = new GridPoint();
        p.lat = centerLat + (i - half) * dLat;
        p.lon = centerLon + (j - half) * dLon;
        p.bortle = IndexGrid.bortleAt(p.lat, p.lon, fallbackBortle);
        pts.push(p);
      }
    }

    const CHUNK: number = 4;
    for (let s = 0; s < pts.length; s += CHUNK) {
      const slice: GridPoint[] = pts.slice(s, s + CHUNK);
      const jobs: Promise<void>[] = slice.map((p: GridPoint) => {
        return WeatherRepo.load(ctx, p.lat, p.lon, false, false).then((b) => {
          if (!b.ok) {
            p.ok = false;
            return;
          }
          const r: ScoreResult = IndexGrid.scoreAt(b.day, p.lat, p.lon, p.bortle, ymd);
          p.score = r.total;
          p.cloud = r.cloud;
          p.wind = r.wind;
          p.ok = true;
        });
      });
      await Promise.all(jobs);
    }
    return pts;
  }
}
