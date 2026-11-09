import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DayData, HourlyWeather } from '../data/Models';
import { WeatherBundle, WeatherSourceKind } from './WeatherTypes';
import { QWeatherSource } from './QWeatherSource';
import { OpenMeteoSource } from './OpenMeteoSource';
import { Logger } from '../../common/Logger';

/**
 * 天气取数：多源降级 + 30 分钟缓存。
 *
 * 华为 Weather Kit 已排除：官方文档明确「仅面向系统应用开放，暂不对外开放」，
 * 第三方应用无法申请，因此境内主源只有和风天气。
 *
 * L0 和风天气（境内主源，KEY 待激活）
 * L1 本地缓存（30 分钟内直接用，超时仍作兜底）
 * L2 无预报（返回 ok=false，界面要明示）
 */
export class WeatherRepo {
  private static readonly STORE: string = 'weather_cache';
  private static readonly TTL: number = 30 * 60 * 1000;
  /**
   * 是否允许境外源兜底。
   * 发布版必须为 false（数据不出境原则）；开发期置 true 便于验证链路。
   */
  private static readonly ALLOW_FOREIGN: boolean = false;

  private static key(lat: number, lon: number): string {
    return (Math.round(lat * 10) / 10).toFixed(1) + ',' + (Math.round(lon * 10) / 10).toFixed(1);
  }

  private static async saveCache(ctx: common.Context, k: string, d: DayData,
    source: string): Promise<void> {
    const p: preferences.Preferences = await preferences.getPreferences(ctx, WeatherRepo.STORE);
    const payload: Record<string, string> = {
      'source': source,
      'ts': Date.now().toString(),
      'json': JSON.stringify(WeatherRepo.toJson(d))
    };
    await p.put(k, JSON.stringify(payload));
    await p.flush();
  }

  private static async readCache(ctx: common.Context, k: string): Promise<WeatherBundle | null> {
    const p: preferences.Preferences = await preferences.getPreferences(ctx, WeatherRepo.STORE);
    const raw: string = p.getSync(k, '') as string;
    if (raw.length === 0) return null;
    try {
      const meta: Record<string, string> = JSON.parse(raw) as Record<string, string>;
      const d: DayData = WeatherRepo.fromJson(meta['json']);
      const ts: number = Number(meta['ts']);
      const b: WeatherBundle = new WeatherBundle();
      b.day = d;
      b.source = meta['source'];
      b.updatedAt = ts;
      b.stale = Date.now() - ts > WeatherRepo.TTL;
      b.ok = true;
      return b;
    } catch (e) {
      return null;
    }
  }

  /** DayData ⇄ JSON（只需要能存能读，字段固定） */
  private static toJson(d: DayData): string {
    const arr: string[] = [];
    for (const h of d.hourly) {
      arr.push([h.cloud, h.cloudLow, h.cloudMid, h.cloudHigh, h.visibility, h.humidity,
        h.pressure, h.windSpeed, h.windDir, h.precip, h.temp, h.dewPoint].join(','));
    }
    const head: string[] = [d.date, d.transp.toString(), d.seeing.toString(), d.aod.toString()];
    return JSON.stringify({ 'head': head, 'rows': arr });
  }

  private static fromJson(s: string): DayData {
    const o: Record<string, Object> = JSON.parse(s) as Record<string, Object>;
    const head: string[] = o['head'] as string[];
    const rows: string[] = o['rows'] as string[];
    const d: DayData = new DayData();
    d.date = head[0];
    d.transp = Number(head[1]);
    d.seeing = Number(head[2]);
    d.aod = Number(head[3]);
    for (const r of rows) {
      const f: string[] = r.split(',');
      const h: HourlyWeather = new HourlyWeather();
      h.cloud = Number(f[0]);
      h.cloudLow = Number(f[1]);
      h.cloudMid = Number(f[2]);
      h.cloudHigh = Number(f[3]);
      h.visibility = Number(f[4]);
      h.humidity = Number(f[5]);
      h.pressure = Number(f[6]);
      h.windSpeed = Number(f[7]);
      h.windDir = Number(f[8]);
      h.precip = Number(f[9]);
      h.temp = Number(f[10]);
      h.dewPoint = f.length > 11 ? Number(f[11]) : -999;
      d.hourly.push(h);
    }
    return d;
  }

  /** 主入口：拿今夜的天气，失败返回 ok=false 的 bundle */
  static async load(ctx: common.Context, lat: number, lon: number,
    forceRefresh: boolean = false): Promise<WeatherBundle> {
    const k: string = WeatherRepo.key(lat, lon);

    if (!forceRefresh) {
      const cached: WeatherBundle | null = await WeatherRepo.readCache(ctx, k);
      if (cached !== null && !cached.stale) return cached;
    }

    // L1 和风
    const qw: DayData | null = await QWeatherSource.fetch(lat, lon);
    if (qw !== null) {
      await WeatherRepo.saveCache(ctx, k, qw, WeatherSourceKind.QWEATHER);
      const b: WeatherBundle = new WeatherBundle();
      b.day = qw;
      b.source = WeatherSourceKind.QWEATHER;
      b.updatedAt = Date.now();
      b.ok = true;
      return b;
    }

    // 开发期兜底：Open-Meteo
    if (WeatherRepo.ALLOW_FOREIGN) {
      const om: DayData | null = await OpenMeteoSource.fetch(lat, lon);
      if (om !== null) {
        await WeatherRepo.saveCache(ctx, k, om, WeatherSourceKind.OPEN_METEO);
        const b: WeatherBundle = new WeatherBundle();
        b.day = om;
        b.source = WeatherSourceKind.OPEN_METEO;
        b.updatedAt = Date.now();
        b.ok = true;
        return b;
      }
    }

    // L2 缓存兜底
    const stale: WeatherBundle | null = await WeatherRepo.readCache(ctx, k);
    if (stale !== null) {
      stale.stale = true;
      Logger.info('weather: fallback to cache');
      return stale;
    }

    const none: WeatherBundle = new WeatherBundle();
    none.ok = false;
    none.source = WeatherSourceKind.NONE;
    return none;
  }
}
