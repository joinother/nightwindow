/**
 * 观星指数：一套模型，三个目标分支。
 * 综合分 = 天气分 × 天空分 ÷ 100
 */
import { City, DayData, HourlyWeather, TargetPoint, Window, ScoreResult } from '../data/Models';
import { airmass, altOf, moonEq, moonAlt, angSep, sunAlt } from '../astro/Astro';

/** 深空候选目标 */
export const DEEP_TARGETS: TargetPoint[] = [
  new TargetPoint('仙女座 M31', 0.712, 41.27, 'deep'),
  new TargetPoint('猎户座 M42', 5.588, -5.39, 'deep'),
  new TargetPoint('昴星团 M45', 3.790, 24.11, 'deep'),
  new TargetPoint('银河中心', 17.761, -29.01, 'deep')
];

export const PLANET_SATURN: TargetPoint = new TargetPoint('土星', 23.00, -6.00, 'planet');
export const MOON_TARGET: TargetPoint = new TargetPoint('月亮', 0, 0, 'moon');

/** 18:00 起算的小时表 */
export const HOURS: number[] = [18, 19, 20, 21, 22, 23, 0, 1, 2, 3, 4, 5, 6];

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

/** 计算目标的最佳窗口 */
export function windowFor(day: DayData, city: City, target: TargetPoint, ymd: number[]): Window | null {
  const minAlt: number = target.kind === 'deep' ? 10 : (target.kind === 'planet' ? 15 : 5);
  const ok: boolean[] = [];

  for (let i = 0; i < HOURS.length; i++) {
    const hh: number = HOURS[i];
    const dd: number = hh < 12 ? ymd[2] + 1 : ymd[2];
    const jd: number = julianDayLocal(ymd[0], ymd[1], dd, hh - 8);

    let alt: number = 0;
    if (target.kind === 'moon') {
      alt = moonAlt(jd, city.lat, city.lon);
    } else {
      alt = altOf(target.ra, target.dec, jd, city.lat, city.lon);
    }

    let good: boolean = day.hourly[i].cloud <= 45 && alt > minAlt;

    const sunA: number = sunAlt(jd, city.lat, city.lon);
    const moonUp: boolean = moonAlt(jd, city.lat, city.lon) > 0;

    if (target.kind === 'deep') {
      // 深空：天文夜（太阳低于 -18°）且无月
      good = good && sunA < -18 && !moonUp;
    } else if (target.kind === 'planet') {
      // 行星：至少民用暮光结束
      good = good && sunA < -6;
    } else {
      // 月面：天足够暗且月亮已升起
      good = good && sunA < -6 && moonUp;
    }

    ok.push(good);
  }

  let bestStart: number = -1;
  let bestLen: number = 0;
  let curStart: number = -1;
  let curLen: number = 0;
  for (let i = 0; i < ok.length; i++) {
    if (ok[i]) {
      if (curStart < 0) { curStart = i; curLen = 1; } else { curLen++; }
      if (curLen > bestLen) { bestLen = curLen; bestStart = curStart; }
    } else {
      curStart = -1;
      curLen = 0;
    }
  }
  if (bestLen < 1) return null;

  const s: number = HOURS[bestStart];
  const e: number = HOURS[bestStart + bestLen - 1];
  const text: string = pad2(s) + ':00 — ' + pad2((e + 1) % 24) + ':00';
  return new Window(bestStart, bestStart + bestLen - 1, text);
}

function pad2(n: number): string {
  return (n < 10 ? '0' : '') + n.toString();
}

/** 本地时间 → 儒略日（hUT = 本地时 - 8） */
function julianDayLocal(y: number, m: number, d: number, hUT: number): number {
  let yy: number = y;
  let mm: number = m;
  if (mm <= 2) { yy -= 1; mm += 12; }
  const A: number = Math.floor(yy / 100);
  const B: number = 2 - A + Math.floor(A / 4);
  return Math.floor(365.25 * (yy + 4716)) + Math.floor(30.6001 * (mm + 1)) + d + B - 1524.5 + hUT / 24;
}

/** 核心评分 */
export function scoreFor(day: DayData, city: City, target: TargetPoint, win: Window | null, ymd: number[]): ScoreResult {
  const res: ScoreResult = new ScoreResult();
  res.targetName = target.name;
  res.window = win;

  const seg: HourlyWeather[] = win === null ? day.hourly : day.hourly.slice(win.start, win.end + 1);

  // 云量：均值 + 稳定度惩罚
  let sum: number = 0;
  for (const h of seg) sum += h.cloud;
  const cMean: number = sum / seg.length;
  let varSum: number = 0;
  for (const h of seg) varSum += (h.cloud - cMean) * (h.cloud - cMean);
  const cSd: number = Math.sqrt(varSum / seg.length);
  const stability: number = 1 - 0.30 * Math.min(1, cSd / 25);
  const cloudS: number = 100 * Math.pow(1 - cMean / 100, 1.35) * stability;

  // 通透：含 AOD 衰减
  const transpS: number = day.transp * Math.exp(-0.6 * day.aod) * 100;

  // 视宁、露点
  const seeingS: number = clamp((3.5 - day.seeing) / 2.5, 0, 1) * 100;
  const dewSpread: number = 6; // 演示值，接入真实露点后替换
  const dewS: number = clamp(dewSpread / 8, 0, 1) * 100;

  // 目标高度角 → 大气质量 → 消光
  const midIdx: number = win === null ? 6 : Math.floor((win.start + win.end) / 2);
  const hh: number = HOURS[midIdx];
  const dd: number = hh < 12 ? ymd[2] + 1 : ymd[2];
  const jd: number = julianDayLocal(ymd[0], ymd[1], dd, hh - 8);

  const alt: number = target.kind === 'moon' ? moonAlt(jd, city.lat, city.lon)
    : altOf(target.ra, target.dec, jd, city.lat, city.lon);
  res.alt = alt;

  const X: number = airmass(alt);
  const airF: number = alt < 5 ? 0.20 : Math.max(0.45, Math.pow(2.512, -0.12 * (X - 1)));

  const weatherRaw: number = 0.55 * cloudS + 0.20 * transpS + 0.15 * seeingS + 0.10 * dewS;
  const weather: number = weatherRaw * airF;

  // 天空分：Bortle × 月光压制
  const ms = moonEq(jd);
  const moonAltDeg: number = moonAlt(jd, city.lat, city.lon);
  let sep: number = 180;
  if (target.kind !== 'moon') {
    sep = angSep(ms.ra / 15, ms.dec, target.ra, target.dec);
  }
  const sepF: number = clamp(1 - sep / 120, 0, 1);
  const moonUp: number = moonAltDeg > 0 ? 1 : 0;
  res.moonAge = ms.age;
  res.moonIllum = ms.f;
  res.moonAltDeg = moonAltDeg;
  res.bortle = city.bortle;
  const moonF: number = 1 - 0.62 * ms.f * moonUp * sepF;

  const bF: number = (10 - city.bortle) / 9;
  let skyBase: number = bF;
  if (target.kind === 'planet') skyBase = 0.60 + 0.40 * bF;
  else if (target.kind === 'moon') skyBase = 0.72 + 0.28 * bF;
  const sky: number = 100 * skyBase * moonF;

  res.total = Math.round(weather * sky / 100);
  res.weather = Math.round(weather);
  res.sky = Math.round(sky);
  res.cloud = Math.round(cloudS);
  res.transp = Math.round(transpS);
  res.seeing = Math.round(seeingS);
  res.dew = Math.round(dewS);

  // 等级
  if (res.total >= 70) res.grade = '极好';
  else if (res.total >= 50) res.grade = '良好';
  else if (res.total >= 30) res.grade = '一般';
  else res.grade = '差';

  // 主要限制
  if (airF < 0.80) {
    res.limit = '目标高度角';
  } else {
    const parts: string[] = ['云量', '通透', '视宁', '露点'];
    const vals: number[] = [res.cloud, res.transp, res.seeing, res.dew];
    let mi: number = 0;
    for (let i = 1; i < vals.length; i++) if (vals[i] < vals[mi]) mi = i;
    res.limit = parts[mi];
  }

  return res;
}
