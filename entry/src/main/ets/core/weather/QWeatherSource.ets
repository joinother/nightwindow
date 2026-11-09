import { http } from '@kit.NetworkKit';
import { DayData, HourlyWeather } from '../data/Models';
import { Logger } from '../../common/Logger';

/**
 * 和风天气（境内主源之一）。
 * 注意：必须用账号专属 Host，devapi 已停用；KEY 勾选 API 权限后有延迟。
 */
export class QWeatherSource {
  private static readonly HOST: string = 'mn6hf38tay.re.qweatherapi.com';
  private static readonly KEY: string = 'TCGX46NXFH';

  private static get(url: string): Promise<string | null> {
    const req: http.HttpRequest = http.createHttp();
    return req.request(url, {
      method: http.RequestMethod.GET,
      header: { 'Accept-Encoding': 'identity' },
      connectTimeout: 10000,
      readTimeout: 10000
    }).then((res: http.HttpResponse) => {
      req.destroy();
      if (res.responseCode !== 200) return null;
      return res.result as string;
    }).catch(() => {
      req.destroy();
      return null;
    });
  }

  static async fetch(lat: number, lon: number): Promise<DayData | null> {
    // 和风要求经纬度顺序：经度,纬度
    const loc: string = lon.toFixed(2) + ',' + lat.toFixed(2);
    const raw: string | null =
      await QWeatherSource.get('https://' + QWeatherSource.HOST + '/v7/weather/24h?location='
        + loc + '&key=' + QWeatherSource.KEY);
    if (raw === null) return null;

    let root: Record<string, Object>;
    try {
      root = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    const code: string = root['code'] as string;
    if (code !== '200') {
      Logger.info('qweather code=' + code);
      return null;
    }

    const list: Record<string, Object>[] = root['hourly'] as Record<string, Object>[];
    if (list === undefined || list.length === 0) return null;

    const d: DayData = new DayData();
    d.date = (list[0]['fxTime'] as string).substring(0, 10);

    let visSum: number = 0;
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
      w.cloudLow = w.cloud;          // 和风不给分层，整层归到低云
      w.cloudMid = 0;
      w.cloudHigh = 0;
      w.visibility = Number(o['vis'] as string);
      w.humidity = Number(o['humidity'] as string);
      w.temp = Number(o['temp'] as string);
      w.windSpeed = Number(o['windSpeed'] as string);
      w.windDir = Number(o['wind360'] as string);
      w.precip = Number(o['precip'] as string);
      w.pressure = Number(o['pressure'] as string);
      d.hourly.push(w);

      visSum += w.visibility;
      windSum += w.windSpeed;
      humSum += w.humidity;
      n++;
    }
    if (n === 0) return null;

    d.transp = Math.max(0.2, Math.min(1, (visSum / n) / 30));
    d.seeing = Math.max(0.8, Math.min(4.0, 1.2 + (windSum / n) / 12));
    d.aod = 0.15;
    return d;
  }
}
