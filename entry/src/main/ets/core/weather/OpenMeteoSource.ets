import { http } from '@kit.NetworkKit';
import { DayData, HourlyWeather } from '../data/Models';
import { Logger } from '../../common/Logger';

/**
 * Open-Meteo：开发期验证用。
 * 分层云量齐全，但没有 AOD 之外的通透指标，且属境外源——发布版默认关闭，
 * 只在 DOMESTIC_ONLY = false 时参与链路。
 */
export class OpenMeteoSource {
  /** 多个坐标一次请求，逗号分隔（实测支持） */
  static async fetch(lat: number, lon: number): Promise<DayData | null> {
    const url: string = 'https://api.open-meteo.com/v1/forecast'
      + '?latitude=' + lat.toFixed(3) + '&longitude=' + lon.toFixed(3)
      + '&hourly=cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high'
      + ',visibility,relative_humidity_2m,temperature_2m,wind_speed_10m'
      + ',wind_direction_10m,precipitation,pressure_msl,dew_point_2m'
      + '&models=ecmwf_ifs&timezone=Asia%2FShanghai&forecast_days=2';
    const req: http.HttpRequest = http.createHttp();
    try {
      const res: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 10000
      });
      req.destroy();
      if (res.responseCode !== 200) return null;
      const root: Record<string, Object> = JSON.parse(res.result as string) as Record<string, Object>;
      return OpenMeteoSource.map(root);
    } catch (e) {
      req.destroy();
      Logger.info('open-meteo failed');
      return null;
    }
  }

  private static num(arr: Object, i: number): number {
    const a: number[] = arr as number[];
    const v: number = a[i];
    return v === undefined || v === null ? 0 : v;
  }

  private static map(root: Record<string, Object>): DayData {
    const h: Record<string, Object> = root['hourly'] as Record<string, Object>;
    const times: string[] = h['time'] as string[];
    const d: DayData = new DayData();
    d.date = times[0].substring(0, 10);

    let visSum: number = 0;
    let windSum: number = 0;
    for (let i = 0; i < times.length && i < 48; i++) {
      const hour: string = times[i].substring(11, 13);
      const hh: number = Number(hour);
      // 只取夜间时段（18:00–06:00），减少无效数据
      const night: boolean = hh >= 17 || hh <= 6;
      if (!night) continue;

      const w: HourlyWeather = new HourlyWeather();
      w.time = i;
      w.cloud = OpenMeteoSource.num(h['cloud_cover'], i);
      w.cloudLow = OpenMeteoSource.num(h['cloud_cover_low'], i);
      w.cloudMid = OpenMeteoSource.num(h['cloud_cover_mid'], i);
      w.cloudHigh = OpenMeteoSource.num(h['cloud_cover_high'], i);
      w.visibility = OpenMeteoSource.num(h['visibility'], i) / 1000; // m → km
      w.humidity = OpenMeteoSource.num(h['relative_humidity_2m'], i);
      w.temp = OpenMeteoSource.num(h['temperature_2m'], i);
      w.windSpeed = OpenMeteoSource.num(h['wind_speed_10m'], i);      // km/h
      w.windDir = OpenMeteoSource.num(h['wind_direction_10m'], i);
      w.precip = OpenMeteoSource.num(h['precipitation'], i);
      w.pressure = OpenMeteoSource.num(h['pressure_msl'], i);
      d.hourly.push(w);
      visSum += w.visibility;
      windSum += w.windSpeed;
    }
    if (d.hourly.length === 0) {
      // 窗口外兜底：直接取前 13 小时
      for (let i = 0; i < 13; i++) d.hourly.push(new HourlyWeather());
    }
    // 通透度：能见度 30km 视为 1.0，5km 视为 0.2
    const visAvg: number = visSum / Math.max(1, d.hourly.length);
    d.transp = Math.max(0.2, Math.min(1, visAvg / 30));
    // 视宁度：用风速粗略估计（km/h → arcsec），风大视宁差
    const windAvg: number = windSum / Math.max(1, d.hourly.length);
    d.seeing = Math.max(0.8, Math.min(4.0, 1.2 + windAvg / 12));
    d.aod = 0.15;
    return d;
  }
}
