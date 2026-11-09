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
export class ApiSource {
  static readonly BASE: string = 'https://skyinstrument.cn/nw';

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
    const j: Record<string, Object> | null =
      await ApiSource.get('/v1/wx?lat=' + lat.toFixed(3) + '&lon=' + lon.toFixed(3));
    if (j === null || j['ok'] !== true) return null;
    const pts: Record<string, Object>[] = j['points'] as Record<string, Object>[];
    if (pts === undefined || pts.length === 0) return null;
    const hours: Record<string, Object>[] = pts[0]['hours'] as Record<string, Object>[];
    if (hours === undefined || hours.length === 0) return null;
    return ApiSource.toDay(hours);
  }

  /** 一次取回整片网格 */
  static async grid(lat: number, lon: number, spanKm: number, n: number): Promise<ApiGridPoint[]> {
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
      g.day = (hours === undefined || hours.length === 0) ? null : ApiSource.toDay(hours);
      out.push(g);
    }
    return out;
  }
}
