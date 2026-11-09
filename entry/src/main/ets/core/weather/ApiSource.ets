import { http } from '@kit.NetworkKit';
import { DayData, HourlyWeather } from '../data/Models';
import { Logger } from '../../common/Logger';

/** 网格里的一个点 */
export class ApiGridPoint {
  lat: number = 0;
  lon: number = 0;
  day: DayData | null = null;
}

/**
 * 今夜星自有服务端（阿里云 ECS，https://skyinstrument.cn/nw）。
 *
 * 值和风 Key 都只在服务端，客户端拿不到；
 * 网格一次请求拿回整片数据，不再逐点打上游。
 */
/** 网格缓存条目 */
class GridEntry {
  ts: number = 0;
  points: ApiGridPoint[] = [];
}

export class ApiSource {
  static readonly BASE: string = 'https://skyinstrument.cn/nw';
  /** 上次取数时上游数据已经放了多久（秒），用来校正本地缓存起点 */
  static lastAgeSec: number = 0;

  /**
   * 客户端网格缓存。
   *
   * 一次 49 点网格约 109KB，而地图来回缩放/平移会反复请求同一片区域。
   * 服务端虽然也有缓存（不打和风），但下载量一点没省——这一层专门省下载。
   */
  private static gridCache: Map<string, GridEntry> = new Map();
  private static readonly GRID_TTL: number = 10 * 60 * 1000;   // 10 分钟
  private static readonly GRID_MAX: number = 30;               // 最多留 30 片区域

  private static get(path: string): Promise<Record<string, Object> | null> {
    const req: http.HttpRequest = http.createHttp();
    return req.request(ApiSource.BASE + path, {
      method: http.RequestMethod.GET,
      header: { 'Accept-Encoding': 'identity' },
      connectTimeout: 8000,
      readTimeout: 15000
    }).then((res: http.HttpResponse) => {
      req.destroy();
      if (res.responseCode !== 200) {
        Logger.info('api http ' + res.responseCode.toString());
        return null;
      }
      try {
        return JSON.parse(res.result as string) as Record<string, Object>;
      } catch (e) {
        return null;
      }
    }).catch((e: Error) => {
      req.destroy();
      Logger.info('api fail ' + e.message);
      return null;
    });
  }

  /** hours 数组 → DayData */
  private static toDay(hours: Record<string, Object>[]): DayData {
    const d: DayData = new DayData();
    if (hours.length > 0) {
      d.date = (hours[0]['t'] as string).substring(0, 10);
    }
    let humSum: number = 0;
    let windSum: number = 0;
    for (let i = 0; i < hours.length; i++) {
      const o: Record<string, Object> = hours[i];
      const w: HourlyWeather = new HourlyWeather();
      w.time = i;
      w.cloud = Number(o['c']);
      w.cloudLow = w.cloud;   // 上游只给总云量，整层按低云处理（保守）
      w.cloudMid = 0;
      w.cloudHigh = 0;
      w.humidity = Number(o['h']);
      w.temp = Number(o['tp']);
      w.dewPoint = Number(o['dw']);
      w.windSpeed = Number(o['ws']);
      w.windDir = Number(o['wd']);
      w.precip = Number(o['p']);
      w.pressure = Number(o['pr']);
      d.hourly.push(w);
      humSum += w.humidity;
      windSum += w.windSpeed;
    }
    const n: number = Math.max(1, hours.length);
    // 通透度：服务端暂未回传 AQI，先用湿度粗估，接入空气质量后再替换
    const hum: number = humSum / n;
    d.transp = Math.max(0.35, Math.min(1, 1 - Math.max(0, (hum - 70) / 30) * 0.45));
    d.seeing = Math.max(0.8, Math.min(4, 1.2 + (windSum / n) / 12));
    d.aod = 0.15;
    return d;
  }

  /** 单点天气 */
  static async wx(lat: number, lon: number): Promise<DayData | null> {
    ApiSource.lastAgeSec = 0;
    const j: Record<string, Object> | null =
      await ApiSource.get('/v1/wx?lat=' + lat.toFixed(3) + '&lon=' + lon.toFixed(3));
    if (j === null || j['ok'] !== true) return null;
    const pts: Record<string, Object>[] = j['points'] as Record<string, Object>[];
    if (pts === undefined || pts.length === 0) return null;
    const ageRaw: Object | undefined = pts[0]['age'];
    ApiSource.lastAgeSec = ageRaw === undefined || ageRaw === null ? 0 : Number(ageRaw);
    const hours: Record<string, Object>[] = pts[0]['hours'] as Record<string, Object>[];
    if (hours === undefined || hours === null || hours.length === 0) return null;
    return ApiSource.toDay(hours);
  }

  /**
   * 7 天逐时（168 小时）→ 按「夜」分组。
   *
   * 一夜 = 当天 18:00 到次日 06:00，所以 22:00 的小时归当天，
   * 02:00 的小时归前一天。
   */
  static async week(lat: number, lon: number): Promise<DayData[]> {
    const j: Record<string, Object> | null =
      await ApiSource.get('/v1/week?lat=' + lat.toFixed(3) + '&lon=' + lon.toFixed(3));
    const out: DayData[] = [];
    if (j === null || j['ok'] !== true) return out;
    const hours: Record<string, Object>[] = j['hours'] as Record<string, Object>[];
    if (hours === undefined || hours === null) return out;

    const byDate: Map<string, HourlyWeather[]> = new Map();
    for (const o of hours) {
      const t: string = o['t'] as string;
      if (t.length < 13) continue;
      const hh: number = Number(t.substring(11, 13));
      if (hh > 6 && hh < 18) continue;          // 白天不属于任何一个观测夜
      let dateStr: string = t.substring(0, 10);
      if (hh <= 6) {
        // 凌晨归到前一天
        const d: Date = new Date(dateStr + 'T00:00:00');
        d.setDate(d.getDate() - 1);
        dateStr = d.getFullYear().toString() + '-'
          + (d.getMonth() + 1).toString().padStart(2, '0') + '-'
          + d.getDate().toString().padStart(2, '0');
      }
      let bucket: HourlyWeather[] | undefined = byDate.get(dateStr);
      if (bucket === undefined) {
        bucket = [];
        byDate.set(dateStr, bucket);
      }
      const w: HourlyWeather = new HourlyWeather();
      w.time = bucket.length;
      w.cloud = Number(o['c']);
      w.cloudLow = w.cloud;
      w.cloudMid = 0;
      w.cloudHigh = 0;
      w.humidity = Number(o['h']);
      w.temp = Number(o['tp']);
      w.dewPoint = Number(o['dw']);
      w.windSpeed = Number(o['ws']);
      w.windDir = Number(o['wd']);
      w.precip = Number(o['p']);
      w.pressure = Number(o['pr']);
      bucket.push(w);
    }

    for (const dateStr of byDate.keys()) {
      const bucket: HourlyWeather[] = byDate.get(dateStr) as HourlyWeather[];
      if (bucket.length < 3) continue;
      // 首夜/末夜可能只有几小时，补齐 13 个槽位（18:00–06:00），
      // 否则评分按 13 个下标取值会越界
      while (bucket.length < 13) {
        const last: HourlyWeather = bucket[bucket.length - 1];
        const clone: HourlyWeather = new HourlyWeather();
        clone.time = bucket.length;
        clone.cloud = last.cloud;
        clone.cloudLow = last.cloudLow;
        clone.cloudMid = last.cloudMid;
        clone.cloudHigh = last.cloudHigh;
        clone.humidity = last.humidity;
        clone.temp = last.temp;
        clone.dewPoint = last.dewPoint;
        clone.windSpeed = last.windSpeed;
        clone.windDir = last.windDir;
        clone.precip = last.precip;
        clone.pressure = last.pressure;
        bucket.push(clone);
      }
      const d: DayData = new DayData();
      d.date = dateStr;
      d.hourly = bucket;
      let humSum: number = 0;
      let windSum: number = 0;
      for (const h of bucket) { humSum += h.humidity; windSum += h.windSpeed; }
      const n: number = bucket.length;
      d.transp = Math.max(0.35, Math.min(1, 1 - Math.max(0, (humSum / n - 70) / 30) * 0.45));
      d.seeing = Math.max(0.8, Math.min(4, 1.2 + (windSum / n) / 12));
      d.aod = 0.15;
      out.push(d);
    }
    out.sort((a: DayData, b: DayData) => a.date < b.date ? -1 : 1);
    return out;
  }

  /** 世界视图：按城市点取数（海面太密会全是 400） */
  static async world(): Promise<ApiGridPoint[]> {
    const j: Record<string, Object> | null = await ApiSource.get('/v1/world');
    const out: ApiGridPoint[] = [];
    if (j === null) return out;
    const pts: Record<string, Object>[] = j['points'] as Record<string, Object>[];
    if (pts === undefined) return out;
    for (const p of pts) {
      const hours: Record<string, Object>[] = p['hours'] as Record<string, Object>[];
      if (hours === undefined || hours === null || hours.length === 0) continue;
      const g: ApiGridPoint = new ApiGridPoint();
      g.lat = Number(p['lat']);
      g.lon = Number(p['lon']);
      g.day = ApiSource.toDay(hours);
      out.push(g);
    }
    return out;
  }

  /** 网格缓存的键：坐标留 2 位（约 1km）、跨度按 10km 归档，缩放几档内算同一片 */
  private static gridKey(lat: number, lon: number, spanKm: number, n: number): string {
    return lat.toFixed(2) + ',' + lon.toFixed(2) + ','
      + Math.round(spanKm / 10).toString() + ',' + n.toString();
  }

  /** 一次取回整片网格（带 10 分钟本地缓存） */
  static async grid(lat: number, lon: number, spanKm: number, n: number): Promise<ApiGridPoint[]> {
    const key: string = ApiSource.gridKey(lat, lon, spanKm, n);
    const hit: GridEntry | undefined = ApiSource.gridCache.get(key);
    if (hit !== undefined && Date.now() - hit.ts < ApiSource.GRID_TTL) {
      console.info('NightWindow gridCache hit ' + key + ' n=' + hit.points.length.toString());
      // 命中就刷新顺序，近似 LRU
      ApiSource.gridCache.delete(key);
      ApiSource.gridCache.set(key, hit);
      return hit.points;
    }
    console.info('NightWindow gridCache miss ' + key);

    const path: string = '/v1/grid?lat=' + lat.toFixed(3) + '&lon=' + lon.toFixed(3)
      + '&span=' + Math.round(spanKm).toString() + '&n=' + n.toString();
    const j: Record<string, Object> | null = await ApiSource.get(path);
    const out: ApiGridPoint[] = [];
    if (j === null) return out;
    const pts: Record<string, Object>[] = j['points'] as Record<string, Object>[];
    if (pts === undefined) return out;
    for (const p of pts) {
      const g: ApiGridPoint = new ApiGridPoint();
      g.lat = Number(p['lat']);
      g.lon = Number(p['lon']);
      const hours: Record<string, Object>[] = p['hours'] as Record<string, Object>[];
      g.day = (hours === undefined || hours === null || hours.length === 0)
        ? null : ApiSource.toDay(hours);
      out.push(g);
    }
    if (out.length > 0) {
      const e: GridEntry = new GridEntry();
      e.ts = Date.now();
      e.points = out;
      ApiSource.gridCache.set(key, e);
      // 超出上限时丢掉最早插入的一片
      while (ApiSource.gridCache.size > ApiSource.GRID_MAX) {
        const oldest: string = ApiSource.gridCache.keys().next().value as string;
        ApiSource.gridCache.delete(oldest);
      }
    }
    return out;
  }
}
