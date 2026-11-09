import { common } from '@kit.AbilityKit';
import { City, DayData, ScoreResult, Window } from '../data/Models';
import { DEEP_TARGETS, scoreFor, windowFor } from '../score/Score';
import { WeatherRepo } from '../weather/WeatherRepo';
import { CITIES } from '../../viewmodel/TonightViewModel';

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
