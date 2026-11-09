import { http } from '@kit.NetworkKit';
import { DayData, HourlyWeather } from '../data/Models';
import { Logger } from '../../common/Logger';

/**
 * 和风天气（境内唯一可用主源）。
 * 华为 Weather Kit 仅系统应用可用，已排除。
 *
 * 两个接口：
 *   /v7/weather/24h            逐小时（含 cloud / dew / wind / precip / humidity）
 *   /airquality/v1/current     空气质量（AQI 用来推通透度与 AOD）
 *
 * 注意：24h 接口不返回能见度 vis，通透度只能由 AQI + 湿度推算。
 */
export class QWeatherSource {
  private static readonly HOST: string = 'mn6hf38tay.re.qweatherapi.com';
  private static readonly KEY: string = '4fc2d23c886d470ebb3491a8afc05241';

  private static get(url: string): Promise<Record<string, Object> | null> {
    const req: http.HttpRequest = http.createHttp();
    return req.request(url, {
      method: http.RequestMethod.GET,
      header: { 'Accept-Encoding': 'identity' },
      connectTimeout: 10000,
      readTimeout: 10000
    }).then((res: http.HttpResponse) => {
      req.destroy();
      if (res.responseCode !== 200) return null;
      try {
        return JSON.parse(res.result as string) as Record<string, Object>;
      } catch (e) {
        return null;
      }
    }).catch(() => {
      req.destroy();
      return null;
    });
  }

  /** AQI → 通透度衰减（0.5 表示严重削减对比度） */
  private static transpFromAqi(aqi: number, humidity: number): number {
    const aqiPenalty: number = Math.min(0.5, aqi / 200 * 0.5);
    const humPenalty: number = Math.max(0, (humidity - 70) / 30) * 0.3;
    return Math.max(0.2, Math.min(1, 1 - aqiPenalty - humPenalty));
  }

  static async fetch(lat: number, lon: number): Promise<DayData | null> {
    const loc: string = lon.toFixed(2) + ',' + lat.toFixed(2);
    const base: string = 'https://' + QWeatherSource.HOST;
    const key: string = QWeatherSource.KEY;

    const raw: Record<string, Object> | null =
      await QWeatherSource.get(base + '/v7/weather/24h?location=' + loc + '&key=' + key);
    if (raw === null) return null;
    const code: string = raw['code'] as string;
    if (code !== '200') {
      Logger.info('qweather code=' + code);
      return null;
    }
    const list: Record<string, Object>[] = raw['hourly'] as Record<string, Object>[];
    if (list === undefined || list.length === 0) return null;

    // 空气质量（可选，失败不影响主流程）
    let aqi: number = 50;
    const air: Record<string, Object> | null =
      await QWeatherSource.get(base + '/airquality/v1/current/' + lat.toFixed(2) + '/'
        + lon.toFixed(2) + '?key=' + key);
    if (air !== null) {
      const idx: Record<string, Object>[] = air['indexes'] as Record<string, Object>[];
      if (idx !== undefined && idx.length > 0) {
        const v: number = Number(idx[0]['aqi']);
        if (!Number.isNaN(v)) aqi = v;
      }
    }

    const d: DayData = new DayData();
    d.date = (list[0]['fxTime'] as string).substring(0, 10);

    let windSum: number = 0;
    let humSum: number = 0;
    let n: number = 0;

    for (let i = 0; i < list.length; i++) {
      const o: Record<string, Object> = list[i];
      const fx: string = o['fxTime'] as string;
      const hh: number = Number(fx.substring(11, 13));
      const night: boolean = hh >= 17 || hh <= 6;
      if (!night) continue;

      const w: HourlyWeather = new HourlyWeather();
      w.time = i;
      w.cloud = Number(o['cloud'] as string);
      w.cloudLow = w.cloud;      // 和风不分层，整层计入低云（保守）
      w.cloudMid = 0;
      w.cloudHigh = 0;
      w.humidity = Number(o['humidity'] as string);
      w.temp = Number(o['temp'] as string);
      w.dewPoint = Number(o['dew'] as string);
      w.windSpeed = Number(o['windSpeed'] as string);
      w.windDir = Number(o['wind360'] as string);
      w.precip = Number(o['precip'] as string);
      w.pressure = Number(o['pressure'] as string);
      d.hourly.push(w);

      windSum += w.windSpeed;
      humSum += w.humidity;
      n++;
    }
    if (n === 0) return null;

    const humAvg: number = humSum / n;
    const windAvg: number = windSum / n;
    d.transp = QWeatherSource.transpFromAqi(aqi, humAvg);
    d.seeing = Math.max(0.8, Math.min(4.0, 1.2 + windAvg / 12));
    d.aod = Math.min(0.6, 0.05 + aqi / 400);
    return d;
  }
}
