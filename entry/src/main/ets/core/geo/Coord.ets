/**
 * 坐标系转换：WGS-84 → GCJ-02（火星坐标）。
 * 中国大陆的地图（含花瓣地图）按 GCJ-02 显示，直接喂 WGS-84 会偏 300–600 m。
 * 天文与光污染计算一律用 WGS-84，进地图前才转。
 */

const PI: number = Math.PI;
const A: number = 6378245.0;           // 克拉索夫斯基椭球长半轴
const EE: number = 0.00669342162296594323; // 偏心率平方

export class LatLon {
  lat: number;
  lon: number;

  constructor(lat: number, lon: number) {
    this.lat = lat;
    this.lon = lon;
  }
}

/** 粗略判断是否在中国境外（境外不做偏移） */
function outOfChina(lat: number, lon: number): boolean {
  return !(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55);
}

function transformLat(x: number, y: number): number {
  let ret: number = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(y * PI) + 40.0 * Math.sin(y / 3.0 * PI)) * 2.0 / 3.0;
  ret += (160.0 * Math.sin(y / 12.0 * PI) + 320 * Math.sin(y * PI / 30.0)) * 2.0 / 3.0;
  return ret;
}

function transformLon(x: number, y: number): number {
  let ret: number = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(x * PI) + 40.0 * Math.sin(x / 3.0 * PI)) * 2.0 / 3.0;
  ret += (150.0 * Math.sin(x / 12.0 * PI) + 300.0 * Math.sin(x / 30.0 * PI)) * 2.0 / 3.0;
  return ret;
}

/** WGS-84 → GCJ-02 */
export function wgs84ToGcj02(lat: number, lon: number): LatLon {
  if (outOfChina(lat, lon)) return new LatLon(lat, lon);
  let dLat: number = transformLat(lon - 105.0, lat - 35.0);
  let dLon: number = transformLon(lon - 105.0, lat - 35.0);
  const radLat: number = lat / 180.0 * PI;
  let magic: number = Math.sin(radLat);
  magic = 1 - EE * magic * magic;
  const sqrtMagic: number = Math.sqrt(magic);
  dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI);
  dLon = (dLon * 180.0) / (A / sqrtMagic * Math.cos(radLat) * PI);
  return new LatLon(lat + dLat, lon + dLon);
}

const RAD: number = Math.PI / 180.0;

/** 两点球面距离（km），入参均为 WGS-84 */
export function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat: number = (lat2 - lat1) * RAD;
  const dLon: number = (lon2 - lon1) * RAD;
  const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
