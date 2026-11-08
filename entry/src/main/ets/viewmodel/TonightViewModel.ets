import { City, DayData, HourlyWeather, ScoreResult, TargetPoint, Window } from '../core/data/Models';
import { scoreFor, windowFor, DEEP_TARGETS } from '../core/score/Score';

/** 一天的概览（七天页用） */
export class DayScore {
  label: string = '';
  weekday: string = '';
  total: number = 0;
  grade: string = '';
  windowText: string = '';
  targetName: string = '';
}

/** 演示数据：成都 2026-11-07（与原型一致，接入真实数据后删除） */
export const CITIES: City[] = [
  new City('成都市', 30.67, 104.06, 8),
  new City('冷湖镇', 38.75, 93.34, 1),
  new City('北京市', 39.90, 116.41, 9),
  new City('上海市', 31.23, 121.47, 9),
  new City('拉萨市', 29.65, 91.14, 5),
  new City('兴隆站', 40.40, 117.57, 4)
];

export class TonightViewModel {
  city: City = CITIES[0];
  ymd: number[] = [2026, 11, 7];
  cityIndex: number = 0;

  setCity(i: number): void {
    this.cityIndex = i;
    this.city = CITIES[i];
  }

  /** 七天概览 */
  week(): DayScore[] {
    const out: DayScore[] = [];
    const weekdays: string[] = ['周五', '周六', '周日', '周一', '周二', '周三', '周四'];
    const base: number[] = [8, 14, 22, 30, 38, 26, 12];
    for (let i = 0; i < 7; i++) {
      const d: DayData = this.demoDayOffset(base[i]);
      const ymd: number[] = [2026, 11, 7 + i];
      let best: ScoreResult | null = null;
      for (const t of DEEP_TARGETS) {
        const w: Window | null = windowFor(d, this.city, t, ymd);
        const r: ScoreResult = scoreFor(d, this.city, t, w, ymd);
        if (best === null || r.total > best.total) best = r;
      }
      const row: DayScore = new DayScore();
      row.label = (11).toString() + '月' + (7 + i).toString() + '日';
      row.weekday = weekdays[i];
      row.total = best === null ? 0 : best.total;
      row.grade = best === null ? '—' : best.grade;
      row.windowText = (best === null || best.window === null) ? '无窗口' : best.window.text;
      row.targetName = best === null ? '' : best.targetName;
      out.push(row);
    }
    return out;
  }

  private demoDayOffset(baseCloud: number): DayData {
    const d: DayData = new DayData();
    d.transp = 0.72;
    d.seeing = 2.1;
    d.aod = 0.15;
    for (let i = 0; i < 13; i++) {
      const h: HourlyWeather = new HourlyWeather();
      h.cloud = Math.min(95, Math.max(0, baseCloud + i * 3));
      d.hourly.push(h);
    }
    return d;
  }

  /** 当前选中的目标（深空取当夜最佳） */
  resolve(): ScoreResult {
    const day: DayData = this.demoDay();
    let best: ScoreResult | null = null;

    for (const t of DEEP_TARGETS) {
      const w: Window | null = windowFor(day, this.city, t, this.ymd);
      const r: ScoreResult = scoreFor(day, this.city, t, w, this.ymd);
      if (best === null || r.total > best.total) best = r;
    }
    return best === null ? new ScoreResult() : best;
  }

  private demoDay(): DayData {
    const d: DayData = new DayData();
    d.date = '2026-11-07';
    d.transp = 0.72;
    d.seeing = 2.1;
    d.aod = 0.15;

    const clouds: number[] = [8, 6, 10, 14, 18, 24, 30, 36, 40, 44, 42, 38, 34];
    for (let i = 0; i < clouds.length; i++) {
      const h: HourlyWeather = new HourlyWeather();
      h.cloud = clouds[i];
      h.visibility = 22;
      h.humidity = 62;
      h.pressure = 1012;
      h.windSpeed = 6;
      h.temp = 14;
      d.hourly.push(h);
    }
    return d;
  }
}
