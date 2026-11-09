import { City, DayData, HourlyWeather, ScoreResult, TargetPoint, Window } from '../core/data/Models';
import { scoreFor, windowFor, DEEP_TARGETS } from '../core/score/Score';
import { nearestDarkSite, DarkHint } from '../core/data/DarkSites';
import { WeatherBundle } from '../core/weather/WeatherTypes';

/** 一天的概览（七天页用） */
@ObservedV2
export class DayScore {
  @Trace label: string = '';
  @Trace weekday: string = '';
  @Trace total: number = 0;
  @Trace grade: string = '';
  @Trace windowText: string = '';
  @Trace targetName: string = '';
}

export const CITIES: City[] = [
  new City('成都市', 30.67, 104.06, 8),
  new City('冷湖镇', 38.75, 93.34, 1),
  new City('北京市', 39.90, 116.41, 9),
  new City('上海市', 31.23, 121.47, 9),
  new City('拉萨市', 29.65, 91.14, 5),
  new City('兴隆站', 40.40, 117.57, 4)
];

/**
 * 状态管理 V2：状态直接住在 ViewModel 里，不再需要往组件搬。
 * 页面用 @Computed 读它，任一 @Trace 字段变化都会驱动刷新。
 */
@ObservedV2
export class TonightViewModel {
  @Trace cityIndex: number = 0;
  @Trace city: City = CITIES[0];
  @Trace result: ScoreResult = new ScoreResult();
  @Trace weekRows: DayScore[] = [];
  @Trace darkHint: DarkHint | null = null;
  /** 昨晚评分（表盘红针做对照） */
  @Trace refScore: number = 0;

  /** 天气状态：是否拿到真实预报、来源、更新时间 */
  @Trace weatherOk: boolean = false;
  @Trace weatherSource: string = '无预报';
  @Trace weatherUpdated: number = 0;
  @Trace weatherStale: boolean = false;

  /** 今夜真实天气（拿到后覆盖演示数据） */
  private dayNow: DayData | null = null;

  /** 某天的天气：今夜用真实数据，其余暂时用演示数据 */
  private dayFor(offset: number): DayData {
    if (offset === 0 && this.dayNow !== null) return this.dayNow;
    const base: number[] = [8, 14, 22, 30, 38, 26, 12];
    const i: number = Math.max(0, Math.min(6, offset));
    return this.demoDayOffset(base[i]);
  }

  /** 由外部注入取到的天气，然后重算 */
  applyWeather(b: WeatherBundle): void {
    this.weatherOk = b.ok;
    this.weatherSource = b.source;
    this.weatherUpdated = b.updatedAt;
    this.weatherStale = b.stale;
    this.dayNow = b.ok ? b.day : null;
    this.refresh();
  }

  /** 相对基准夜（2026-11-07）的偏移，右滑 +1、左滑 -1 */
  @Trace dayOffset: number = 0;

  private static readonly BASE: number[] = [2026, 11, 7];

  /** 当前夜的年月日 */
  @Computed
  get ymd(): number[] {
    const d: Date = new Date(TonightViewModel.BASE[0], TonightViewModel.BASE[1] - 1,
      TonightViewModel.BASE[2] + this.dayOffset);
    return [d.getFullYear(), d.getMonth() + 1, d.getDate()];
  }

  @Computed
  get dateText(): string {
    const d: Date = new Date(TonightViewModel.BASE[0], TonightViewModel.BASE[1] - 1,
      TonightViewModel.BASE[2] + this.dayOffset);
    const wd: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 ' + wd[d.getDay()];
  }

  /** 切到下一晚（+1）或上一晚（-1） */
  changeNight(delta: number): void {
    this.dayOffset = this.dayOffset + delta;
    this.refresh();
  }

  /** 派生值：城市名 */
  @Computed
  get cityName(): string {
    return this.city.name;
  }

  /** 换城市并重算（页面不再手工搬运） */
  setCity(i: number): void {
    this.cityIndex = i;
    this.city = CITIES[i];
    this.refresh();
  }

  refresh(): void {
    this.result = this.resolve();
    this.weekRows = this.week();
    this.darkHint = nearestDarkSite(this.city.lat, this.city.lon, this.city.bortle);
    this.refScore = this.scoreAt(this.dayOffset - 1);
  }

  /** 七天概览 */
  week(): DayScore[] {
    const out: DayScore[] = [];
    const wdName: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    const base: number[] = [8, 14, 22, 30, 38, 26, 12];
    for (let i = 0; i < 7; i++) {
      const d: DayData = this.demoDayOffset(base[i]);
      const dt: Date = new Date(TonightViewModel.BASE[0], TonightViewModel.BASE[1] - 1,
        TonightViewModel.BASE[2] + this.dayOffset + i);
      const ymd: number[] = [dt.getFullYear(), dt.getMonth() + 1, dt.getDate()];
      let best: ScoreResult | null = null;
      for (const t of DEEP_TARGETS) {
        const w: Window | null = windowFor(d, this.city, t, ymd);
        const r: ScoreResult = scoreFor(d, this.city, t, w, ymd);
        if (best === null || r.total > best.total) best = r;
      }
      const row: DayScore = new DayScore();
      row.label = (dt.getMonth() + 1).toString() + '月' + dt.getDate().toString() + '日';
      row.weekday = wdName[dt.getDay()];
      row.total = best === null ? 0 : best.total;
      row.grade = best === null ? '—' : best.grade;
      row.windowText = (best === null || best.window === null) ? '无窗口' : best.window.text;
      row.targetName = best === null ? '' : best.targetName;
      out.push(row);
    }
    return out;
  }

  /** 七天汇总文案（低分夜带上最近的暗夜） */
  @Computed
  get weekSummary(): string {
    if (this.weekRows.length === 0) return '';
    let best: DayScore = this.weekRows[0];
    for (const r of this.weekRows) {
      if (r.total > best.total) best = r;
    }
    if (best.total >= 30) {
      return '本周最佳 ' + best.label + ' · ' + best.total.toString() + ' 分';
    }
    if (this.darkHint !== null) {
      return '整周偏弱 · 最近的暗夜 ' + this.darkHint.bearing + ' ' + this.darkHint.km.toString()
        + ' km ' + this.darkHint.name + '（Bortle ' + this.darkHint.bortle.toString() + '）';
    }
    return '整周偏弱 · 建议换观测地';
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
  /** 任意偏移那天的综合分（表盘红针用） */
  scoreAt(offset: number): number {
    const dt: Date = new Date(TonightViewModel.BASE[0], TonightViewModel.BASE[1] - 1,
      TonightViewModel.BASE[2] + offset);
    const ymd: number[] = [dt.getFullYear(), dt.getMonth() + 1, dt.getDate()];
    const day: DayData = this.dayFor(offset);
    let best: number = 0;
    for (const t of DEEP_TARGETS) {
      const w: Window | null = windowFor(day, this.city, t, ymd);
      const r: ScoreResult = scoreFor(day, this.city, t, w, ymd);
      if (r.total > best) best = r.total;
    }
    return best;
  }

  resolve(): ScoreResult {
    const day: DayData = this.dayFor(0);
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
    // 演示用的分层构成：低云为主，少量中云，入夜后高云增多
    const lowRatio: number[] = [0.7, 0.7, 0.65, 0.6, 0.6, 0.55, 0.5, 0.45, 0.45, 0.4, 0.4, 0.45, 0.5];
    const midRatio: number[] = [0.2, 0.2, 0.2, 0.25, 0.25, 0.25, 0.3, 0.3, 0.3, 0.35, 0.35, 0.3, 0.3];
    for (let i = 0; i < clouds.length; i++) {
      const h: HourlyWeather = new HourlyWeather();
      h.cloud = clouds[i];
      h.cloudLow = Math.round(clouds[i] * lowRatio[i]);
      h.cloudMid = Math.round(clouds[i] * midRatio[i]);
      h.cloudHigh = Math.max(0, clouds[i] - h.cloudLow - h.cloudMid);
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
