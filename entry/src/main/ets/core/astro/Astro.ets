/**
 * 天文计算内核：纯函数，不依赖任何 @ohos 系统能力。
 * 口径与原型一致（Meeus 简化星历）。
 */

const RAD: number = Math.PI / 180.0;

/** 儒略日 */
export function julianDay(y: number, m: number, d: number, hUT: number): number {
  let yy: number = y;
  let mm: number = m;
  if (mm <= 2) {
    yy -= 1;
    mm += 12;
  }
  const A: number = Math.floor(yy / 100);
  const B: number = 2 - A + Math.floor(A / 4);
  return Math.floor(365.25 * (yy + 4716)) + Math.floor(30.6001 * (mm + 1)) + d + B - 1524.5 + hUT / 24;
}

/** 月亮赤经赤纬、照亮比例、月龄 */
export class MoonState {
  ra: number;
  dec: number;
  f: number;
  age: number;

  constructor(ra: number, dec: number, f: number, age: number) {
    this.ra = ra;
    this.dec = dec;
    this.f = f;
    this.age = age;
  }
}

export function moonEq(jd: number): MoonState {
  const T: number = (jd - 2451545.0) / 36525;
  const Lp: number = (218.3164477 + 481267.88123421 * T) % 360;
  const Dm: number = (297.8501921 + 445267.1114034 * T) % 360;
  const M: number = (357.5291092 + 35999.0502909 * T) % 360;
  const Mp: number = (134.9633964 + 477198.8675055 * T) % 360;
  const F: number = (93.2720950 + 483202.0175233 * T) % 360;

  const lon: number = Lp + 6.289 * Math.sin(Mp * RAD) - 1.274 * Math.sin((2 * Dm - Mp) * RAD)
    + 0.658 * Math.sin(2 * Dm * RAD) + 0.214 * Math.sin(2 * Mp * RAD)
    - 0.186 * Math.sin(M * RAD) - 0.114 * Math.sin(2 * F * RAD);
  const lat: number = 5.128 * Math.sin(F * RAD) + 0.281 * Math.sin((Mp + F) * RAD)
    - 0.278 * Math.sin((F - Mp) * RAD) - 0.173 * Math.sin((2 * Dm - F) * RAD);

  const eps: number = 23.439291 - 0.0130042 * T;
  const x: number = Math.cos(lat * RAD) * Math.cos(lon * RAD);
  const y: number = Math.cos(eps * RAD) * Math.cos(lat * RAD) * Math.sin(lon * RAD)
    - Math.sin(eps * RAD) * Math.sin(lat * RAD);
  const z: number = Math.sin(eps * RAD) * Math.cos(lat * RAD) * Math.sin(lon * RAD)
    + Math.cos(eps * RAD) * Math.sin(lat * RAD);

  const ra: number = Math.atan2(y, x) / RAD;
  const dec: number = Math.asin(z) / RAD;

  const L0: number = (280.4665 + 36000.7698 * T) % 360;
  const sunLon: number = L0 + 1.9146 * Math.sin(M * RAD) + 0.0200 * Math.sin(2 * M * RAD);
  const el: number = ((lon - sunLon) % 360 + 360) % 360;

  return new MoonState(ra, dec, (1 - Math.cos(el * RAD)) / 2, el / 360 * 29.53);
}

/** 太阳（黄经）— 用于暮光 */
export function sunEclipticLon(jd: number): number {
  const T: number = (jd - 2451545.0) / 36525;
  const L0: number = (280.4665 + 36000.7698 * T) % 360;
  const M: number = (357.5291092 + 35999.0502909 * T) % 360;
  return (L0 + 1.9146 * Math.sin(M * RAD) + 0.0200 * Math.sin(2 * M * RAD)) % 360;
}

/** 太阳赤经赤纬 */
export class RaDec {
  ra: number;
  dec: number;
  constructor(ra: number, dec: number) {
    this.ra = ra;
    this.dec = dec;
  }
}

export function sunRaDec(jd: number): RaDec {
  const lon: number = sunEclipticLon(jd);
  const T: number = (jd - 2451545.0) / 36525;
  const eps: number = 23.439291 - 0.0130042 * T;
  const x: number = Math.cos(lon * RAD);
  const y: number = Math.cos(eps * RAD) * Math.sin(lon * RAD);
  const z: number = Math.sin(eps * RAD) * Math.sin(lon * RAD);
  return new RaDec(Math.atan2(y, x) / RAD, Math.asin(z) / RAD);
}

/** 高度角（ra 单位：小时；dec 单位：度） */
export function altOf(raH: number, decDeg: number, jd: number, lat: number, lon: number): number {
  const gmst: number = 280.46061837 + 360.98564736629 * (jd - 2451545.0);
  const lst: number = ((gmst + lon) % 360 + 360) % 360;
  const H: number = (lst - raH * 15) * RAD;
  const phi: number = lat * RAD;
  const dec: number = decDeg * RAD;
  const alt: number = Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(H));
  return alt / RAD;
}

/** 月亮高度角 */
export function moonAlt(jd: number, lat: number, lon: number): number {
  const m: MoonState = moonEq(jd);
  return altOf(m.ra / 15, m.dec, jd, lat, lon);
}

/** 大气质量（Kasten-Young） */
export function airmass(alt: number): number {
  if (alt <= 0) return 40;
  return 1 / (Math.sin(alt * RAD) + 0.50572 * Math.pow(alt + 6.07995, -1.6364));
}

/** 角距（度） */
export function angSep(ra1H: number, dec1: number, ra2H: number, dec2: number): number {
  const a1: number = ra1H * 15 * RAD;
  const a2: number = ra2H * 15 * RAD;
  const d1: number = dec1 * RAD;
  const d2: number = dec2 * RAD;
  const c: number = Math.sin(d1) * Math.sin(d2) + Math.cos(d1) * Math.cos(d2) * Math.cos(a1 - a2);
  return Math.acos(Math.min(1, Math.max(-1, c))) / RAD;
}

/** 世界时 → 本地时间字符串（东八区） */
export function hourText(hourIndex: number, baseHour: number): string {
  const h: number = (baseHour + hourIndex) % 24;
  return (h < 10 ? '0' : '') + h.toString() + ':00';
}

/** 太阳高度角（用于判断天文夜） */
export function sunAlt(jd: number, lat: number, lon: number): number {
  const sd: RaDec = sunRaDec(jd);
  return altOf(sd.ra / 15, sd.dec, jd, lat, lon);
}
