/** 城市 */
export class City {
  name: string;
  lat: number;
  lon: number;
  bortle: number;

  constructor(name: string, lat: number, lon: number, bortle: number) {
    this.name = name;
    this.lat = lat;
    this.lon = lon;
    this.bortle = bortle;
  }
}

/** 逐小时天气 */
export class HourlyWeather {
  time: number = 0;        // epoch ms
  cloud: number = 0;       // 0-100
  visibility: number = 20; // km
  humidity: number = 60;   // 0-100
  pressure: number = 1013; // hPa
  windSpeed: number = 5;   // km/h
  temp: number = 15;       // °C
}

/** 一天的天气数据（含非逐小时的辅助量） */
export class DayData {
  date: string = '';          // YYYY-MM-DD
  hourly: HourlyWeather[] = [];
  transp: number = 0.72;      // 透明度 0-1
  seeing: number = 2.1;       // 视宁度 arcsec
  aod: number = 0.15;         // 气溶胶光学厚度
}

/** 观测目标 */
export class TargetPoint {
  name: string;
  ra: number;   // 小时
  dec: number;  // 度
  kind: string; // deep | planet | moon

  constructor(name: string, ra: number, dec: number, kind: string) {
    this.name = name;
    this.ra = ra;
    this.dec = dec;
    this.kind = kind;
  }
}

/** 观测窗口 */
export class Window {
  start: number;   // 起始小时（18 起算的索引）
  end: number;
  text: string;

  constructor(start: number, end: number, text: string) {
    this.start = start;
    this.end = end;
    this.text = text;
  }
}

/** 评分结果 */
export class ScoreResult {
  total: number = 0;
  grade: string = '';
  limit: string = '';
  weather: number = 0;
  sky: number = 0;
  cloud: number = 0;
  transp: number = 0;
  seeing: number = 0;
  dew: number = 0;
  alt: number = 0;
  targetName: string = '';
  moonAge: number = 0;      // 月龄（天）
  moonIllum: number = 0;    // 照亮比例 0-1
  moonAltDeg: number = 0;   // 月亮高度角
  bortle: number = 5;       // 当地 Bortle
  window: Window | null = null;
}
