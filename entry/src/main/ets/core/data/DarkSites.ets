/**
 * 暗夜站点表（内置演示数据）。
 * 真实实现应替换为 VIIRS 光污染栅格 + 视野搜索，见设计文档 §6.9。
 */
@ObservedV2
export class DarkSite {
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

@ObservedV2
export class DarkHint {
  @Trace name: string = '';
  @Trace bortle: number = 0;
  @Trace km: number = 0;
  @Trace bearing: string = '';
  @Trace lat: number = 0;
  @Trace lon: number = 0;
}

const SITES: DarkSite[] = [
  new DarkSite('冷湖镇', 38.75, 93.34, 1),
  new DarkSite('阿里暗夜公园', 32.50, 80.10, 1),
  new DarkSite('纳木错', 30.75, 90.95, 2),
  new DarkSite('巴朗山', 30.87, 102.90, 2),
  new DarkSite('西岭雪山', 30.75, 103.17, 3),
  new DarkSite('兴隆观测站', 40.40, 117.57, 4),
  new DarkSite('密云不老屯', 40.55, 116.98, 4),
  new DarkSite('天荒坪', 30.47, 119.57, 4),
  new DarkSite('海坨山', 40.60, 115.80, 4),
  new DarkSite('秦岭太白山', 33.95, 107.75, 3)
];

const RAD: number = Math.PI / 180.0;

/** 两点距离（km） */
function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat: number = (lat2 - lat1) * RAD;
  const dLon: number = (lon2 - lon1) * RAD;
  const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** 方位（八方向） */
function bearingOf(lat1: number, lon1: number, lat2: number, lon2: number): string {
  const y: number = Math.sin((lon2 - lon1) * RAD) * Math.cos(lat2 * RAD);
  const x: number = Math.cos(lat1 * RAD) * Math.sin(lat2 * RAD)
    - Math.sin(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.cos((lon2 - lon1) * RAD);
  let deg: number = Math.atan2(y, x) / RAD;
  deg = (deg + 360) % 360;
  const names: string[] = ['正北', '东北', '正东', '东南', '正南', '西南', '正西', '西北'];
  return names[Math.round(deg / 45) % 8];
}

/** 找最近的、比当前暗至少 1 档的站点 */
export function nearestDarkSite(lat: number, lon: number, currentBortle: number): DarkHint | null {
  let best: DarkSite | null = null;
  let bestKm: number = 1e9;
  for (const s of SITES) {
    if (s.bortle >= currentBortle - 1) continue;
    const km: number = distanceKm(lat, lon, s.lat, s.lon);
    if (km < bestKm) {
      bestKm = km;
      best = s;
    }
  }
  if (best === null) return null;
  const hint: DarkHint = new DarkHint();
  hint.name = best.name;
  hint.bortle = best.bortle;
  hint.km = Math.round(bestKm);
  hint.bearing = bearingOf(lat, lon, best.lat, best.lon);
  hint.lat = best.lat;
  hint.lon = best.lon;
  return hint;
}
