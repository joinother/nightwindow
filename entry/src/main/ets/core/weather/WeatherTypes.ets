import { DayData } from '../data/Models';

/** 数据来源标记，用于「数据」页展示与降级判断 */
export enum WeatherSourceKind {
  WEATHER_KIT = '华为 Weather Kit',
  QWEATHER = '和风天气',
  OPEN_METEO = 'Open-Meteo（开发用）',
  CACHE = '本地缓存',
  NONE = '无预报'
}

/** 一次取数的结果 */
@ObservedV2
export class WeatherBundle {
  @Trace day: DayData = new DayData();
  @Trace source: string = WeatherSourceKind.NONE;
  @Trace updatedAt: number = 0;   // epoch ms
  @Trace stale: boolean = false;  // 是否来自缓存
  @Trace ok: boolean = false;
}
