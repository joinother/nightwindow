/**
 * 数据类型。
 * 全部使用状态管理 V2（@ObservedV2 + @Trace）：属性级深度观测，
 * 改一个字段就能驱动 UI，不必整体替换对象。
 */

/** 城市 */
@ObservedV2
export class City {
  @Trace name: string;
  @Trace lat: number;
  @Trace lon: number;
  @Trace bortle: number;

  constructor(name: string, lat: number, lon: number, bortle: number) {
    this.name = name;
    this.lat = lat;
    this.lon = lon;
    this.bortle = bortle;
  }
}

/** 逐小时天气 */
@ObservedV2
export class HourlyWeather {
  @Trace time: number = 0;        // epoch ms
  @Trace cloud: number = 0;
  @Trace cloudPct: number = 0;   // 窗口内平均云量 0-100（用于反馈校准）       // 0-100 总云量
  @Trace cloudLow: number = 0;    // 0-100 低云
  @Trace cloudMid: number = 0;    // 0-100 中云
  @Trace cloudHigh: number = 0;   // 0-100 高云
  @Trace visibility: number = 20; // km
  @Trace humidity: number = 60;   // 0-100
  @Trace pressure: number = 1013; // hPa
  @Trace windSpeed: number = 5;   // km/h
  @Trace temp: number = 15;       // °C
}

/** 一天的天气数据（含非逐小时的辅助量） */
@ObservedV2
export class DayData {
  @Trace date: string = '';          // YYYY-MM-DD
  @Trace hourly: HourlyWeather[] = [];
  @Trace transp: number = 0.72;      // 透明度 0-1
  @Trace seeing: number = 2.1;       // 视宁度 arcsec
  @Trace aod: number = 0.15;         // 气溶胶光学厚度
}

/** 观测目标 */
@ObservedV2
export class TargetPoint {
  @Trace name: string;
  @Trace ra: number;   // 小时
  @Trace dec: number;  // 度
  @Trace kind: string; // deep | planet | moon

  constructor(name: string, ra: number, dec: number, kind: string) {
    this.name = name;
    this.ra = ra;
    this.dec = dec;
    this.kind = kind;
  }
}

/** 观测窗口 */
@ObservedV2
export class Window {
  @Trace start: number;   // 起始小时（18 起算的索引）
  @Trace end: number;
  @Trace text: string;

  constructor(start: number, end: number, text: string) {
    this.start = start;
    this.end = end;
    this.text = text;
  }
}

/** 评分结果 */
@ObservedV2
export class ScoreResult {
  @Trace total: number = 0;
  @Trace grade: string = '';
  @Trace limit: string = '';
  @Trace weather: number = 0;
  @Trace sky: number = 0;
  @Trace cloud: number = 0;
  @Trace cloudPct: number = 0;   // 窗口内平均云量 0-100（用于反馈校准）
  @Trace transp: number = 0;
  @Trace seeing: number = 0;
  @Trace dew: number = 0;
  @Trace alt: number = 0;
  @Trace targetName: string = '';
  @Trace window: Window | null = null;
  @Trace moonAge: number = 0;      // 月龄（天）
  @Trace moonIllum: number = 0;    // 照亮比例 0-1
  @Trace moonAltDeg: number = 0;   // 月亮高度角
  @Trace bortle: number = 5;       // 当地 Bortle
}
