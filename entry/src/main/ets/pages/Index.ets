import { TonightViewModel, DayScore, CITIES } from '../viewmodel/TonightViewModel';
import { ScoreResult, City } from '../core/data/Models';
import { nearestDarkSite, DarkHint } from '../core/data/DarkSites';
import { FeedbackStore } from '../common/FeedbackStore';
import { setCloudBias } from '../core/score/Score';
import { FeedbackUploader } from '../common/FeedbackUploader';
import { WeatherRepo } from '../core/weather/WeatherRepo';
import { WeatherBundle } from '../core/weather/WeatherTypes';
import { GridPoint, IndexGrid } from '../core/map/IndexGrid';
import { ApiGridPoint, ApiSource } from '../core/weather/ApiSource';
import { Logger } from '../common/Logger';
import { ScoreGauge } from '../view/ScoreGauge';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { sensor } from '@kit.SensorServiceKit';
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wgs84ToGcj02, LatLon, distanceKm } from '../core/geo/Coord';
import { geoLocationManager } from '@kit.LocationKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { uiMaterial, window, curves } from '@kit.ArkUI';

/**
 * 首屏：海报式，只有一个数字。
 * 背景为真实星空图 + 自下而上的暗色遮罩，保证文字可读。
 */
@Entry
@ComponentV2
struct Index {
  // —— UI 局部状态（V2：@Local）——
  @Local showSheet: boolean = false;
  @Local showCity: boolean = false;
  @Local showFeedback: boolean = false;
  @Local shareStats: boolean = true;
  @Local showMap: boolean = false;
  @Local gridPts: GridPoint[] = [];
  @Local gridLoading: boolean = false;
  @Local gridHint: string = '';
  @Local fieldTick: number = 0;
  private canvasCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasReady: boolean = false;
  private mapW: number = 0;
  private mapH: number = 0;
  private fieldPts: GridPoint[] = [];
  private fieldN: number = 8;
  private userLat: number = 0;      // 真实定位坐标，0 表示未知
  private userLon: number = 0;
  private lastSampleLat: number = 0;
  private lastSampleLon: number = 0;
  private lastSampleZoom: number = -1;
  private lastSampleTs: number = 0;
  private sampleCount: number = 0;
  private idleTimer: number = -1;
  private camTimer: number = -1;
  private minuteTimer: number = -1;
  @Local refreshing: boolean = false;
  @Local pullOffset: number = 0;
  @Local refreshPrompt: ResourceStr = '下拉刷新';
  @Local refreshHint: string = '';
  private hintTimer: number = -1;
  @Local showMenu: boolean = false;
  @Local mapError: string = '';
  @Local markerLat: number = 0;
  @Local markerLon: number = 0;
  @Local locating: boolean = false;
  @Local locHint: string = '';
  @Local locAccuracy: number = -1;   // -1 = 无精确定位
  @Local locSource: string = '';     // '精确定位' | '城市级' | ''
  @Local pageIndex: number = 0;
  @Local insetTop: number = 0;
  @Local insetLeft: number = 0;
  @Local insetRight: number = 0;
  @Local tiltX: number = 0;   // -1..1 左右倾斜
  @Local tiltY: number = 0;   // -1..1 前后倾斜
  @Local bgIndex: number = 0;
  @Local pgAlpha: number = 1;
  @Local pgShiftX: number = 0;
  @Local bgPrev: number = 0;
  @Local bgFade: number = 1;
  /** 与 bgList 同序的版权归属 */
  private bgCredit: string[] = [
    'NASA / ESA / Hubble Heritage (STScI/AURA) · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0',
    'NASA / ESA / Hubble · CC BY 4.0'
  ];
  private bgList: Resource[] = [
    $r('app.media.bg_pillars'),
    $r('app.media.bg_heic0515a'),
    $r('app.media.bg_heic0604a'),
    $r('app.media.bg_heic0715a'),
    $r('app.media.bg_heic0910h'),
    $r('app.media.bg_heic1105a'),
    $r('app.media.bg_heic1307a')
  ];
  @Local mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 30.67, longitude: 104.06 }, zoom: 10 },
    dayNightMode: mapCommon.DayNightMode.NIGHT
  };

  // —— 业务状态住在 ViewModel 里，这里只读 ——
  private vm: TonightViewModel = new TonightViewModel();
  private mapCtl: map.MapComponentController | null = null;
  private winRef: window.Window | null = null;
  private insetsBound: boolean = false;
  private tiltBound: boolean = false;
  private tiltSamples: number = 0;
  private baseGX: number = 0;
  private baseGY: number = 0;
  private hasBase: boolean = false;
  private screenRot: number = 0;
  private lastSwipeMs: number = 0;

  // 系统沉浸式材质：仅 Navigation 标题栏 / 底部 TabBar 生效
  private glassThin: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: {}
  });
  private glassUltraThin: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: {}
  });

  @Computed
  get result(): ScoreResult {
    return this.vm.result;
  }

  @Computed
  get weekRows(): DayScore[] {
    return this.vm.weekRows;
  }

  @Computed
  get darkHint(): DarkHint | null {
    return this.vm.darkHint;
  }

  @Computed
  get cityName2(): string {
    return this.vm.cityName;
  }
  private cityName: string = '成都市';
  private dateText: string = '11月7日 周五';
  private clock: string = '';

  /** 昨天没反馈过就显示反馈行 */
  private async checkFeedback(): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      const d: Date = new Date();
      d.setDate(d.getDate() - 1);
      const key: string = this.dateKey(d);
      const done: boolean = await FeedbackStore.has(ctx, key);
      this.showFeedback = !done;
    } catch (e) {
      this.showFeedback = false;
    }
  }

  /** 下拉刷新：先过限流，再强制绕缓存重取 */
  private async pullToRefresh(): Promise<void> {
    if (this.refreshing) return;
    const ctx: common.Context = getContext(this) as common.Context;
    const gate: Record<string, number> = await WeatherRepo.canManualRefresh(ctx);
    if (gate['ok'] !== 1) {
      this.refreshing = false;
      this.showHint(gate['waitMin'] < 0
        ? '今天刷新次数已用完'
        : ('刚更新过 · ' + gate['waitMin'].toString() + ' 分钟后再试'));
      return;
    }
    this.refreshing = true;
    this.refreshHint = '';
    let ok: boolean = false;
    try {
      await this.loadWeather(true);
      ok = this.vm.weatherOk;
      if (ok) await WeatherRepo.markManualRefresh(ctx);
    } catch (e) {
      const err = e as Error;
      console.error('NightWindow refresh error: ' + err.message);
      ok = false;
    }
    // 官方 promptText：转圈 → 「刷新成功」→ 自动弹回
    this.refreshPrompt = ok ? '刷新成功' : '刷新失败';
    setTimeout(() => {
      this.refreshing = false;
      this.refreshPrompt = '下拉刷新';
    }, 1200);
  }

  /** 顶部的短提示，2 秒后自动消失 */
  private showHint(text: string): void {
    console.info('NightWindow hint: ' + text);
    this.refreshHint = text;
    if (this.hintTimer > 0) clearTimeout(this.hintTimer);
    this.hintTimer = setTimeout(() => { this.refreshHint = ''; }, 2000);
  }

  /** 拉取今夜天气并重算分数 */
  private async loadWeather(force: boolean): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      const b: WeatherBundle = await WeatherRepo.load(ctx, this.vm.city.lat, this.vm.city.lon, force);
      this.vm.applyWeather(b);
      Logger.info('weather: ok=' + b.ok + ' source=' + b.source + ' stale=' + b.stale);
    } catch (e) {
      console.warn('loadWeather failed');
    }
  }

  /** 攒批上报：联网且用户允许时把本地反馈队列发出去 */
  private async flushFeedback(): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      await FeedbackUploader.flush(ctx, this.vm.city.lat, this.vm.city.lon, '1.0.0');
    } catch (e) {
      console.warn('flushFeedback failed');
    }
  }

  /** 用历史反馈校正云量预报偏差，然后重算 */
  private async applyLearnedBias(): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      const b: number = await FeedbackStore.cloudBias(ctx);
      if (b !== 0) {
        setCloudBias(b);
        this.vm.refresh();
        Logger.info('cloud bias applied: ' + b.toFixed(1));
      }
    } catch (e) {
      console.warn('applyLearnedBias failed');
    }
  }

  private async loadSharePref(): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      this.shareStats = await FeedbackUploader.shareEnabled(ctx);
    } catch (e) {
      this.shareStats = true;
    }
  }

  private async toggleShare(on: boolean): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      await FeedbackUploader.setShare(ctx, on);
      if (on) this.flushFeedback();
    } catch (e) {
      console.warn('toggleShare failed');
    }
  }

  /** 天气更新时间 → HH:mm */
  private updatedClock(): string {
    if (this.vm.weatherUpdated <= 0) return '—';
    const d: Date = new Date(this.vm.weatherUpdated);
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    return (h < 10 ? '0' : '') + h.toString() + ':' + (m < 10 ? '0' : '') + m.toString();
  }

  private dateKey(d: Date): string {
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return d.getFullYear().toString() + '-' + (m < 10 ? '0' : '') + m.toString()
      + '-' + (day < 10 ? '0' : '') + day.toString();
  }

  private async submitFeedback(v: number): Promise<void> {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      const d: Date = new Date();
      d.setDate(d.getDate() - 1);
      await FeedbackStore.save(ctx, this.dateKey(d), v, this.vm.result.cloudPct);
    } catch (e) {
      // ignore
    }
    this.showFeedback = false;
  }

  /** 城市级一次性定位：拒绝授权也不影响手动选城市 */
  private async useMyLocation(): Promise<void> {
    if (this.locating) return;
    this.locating = true;
    this.locHint = '';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      // 两档权限一起申请：大致 + 精确
      const perms: Permissions[] = [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ];
      const at = abilityAccessCtrl.createAtManager();
      const res = await at.requestPermissionsFromUser(ctx, perms);
      const coarseOk: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      const fineOk: boolean = res.authResults.length > 1 && res.authResults[1] === 0;
      if (!coarseOk) {
        this.locHint = '未授权 · 可手动选择';
        this.locating = false;
        return;
      }

      // 第一段：缓存位置，立刻出分
      try {
        const last: geoLocationManager.Location = geoLocationManager.getLastLocation();
        this.snapToNearest(last.latitude, last.longitude, fineOk ? last.accuracy : -1);
        this.showCity = false;
      } catch (e) {
        // 没有缓存就跳过，等第二段
      }

      // 第二段：异步取当前位置，静默更新
      const req: geoLocationManager.CurrentLocationRequest = {
        priority: fineOk ? geoLocationManager.LocationRequestPriority.ACCURACY
          : geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        maxAccuracy: fineOk ? 50 : 0,
        timeoutMs: 8000
      };
      const loc: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(req);
      this.snapToNearest(loc.latitude, loc.longitude, fineOk ? loc.accuracy : -1);
      this.showCity = false;
    } catch (e) {
      const err = e as BusinessError;
      this.locHint = '定位失败 ' + err.code;
    } finally {
      this.locating = false;
    }
  }

  /** 按坐标吸附到最近城市，并记录精度 */
  private snapToNearest(lat: number, lon: number, accuracy: number): void {
    this.userLat = lat;
    this.userLon = lon;
    let best: number = 0;
    let bestKm: number = 1e9;
    for (let i = 0; i < CITIES.length; i++) {
      const km: number = distanceKm(lat, lon, CITIES[i].lat, CITIES[i].lon);
      if (km < bestKm) {
        bestKm = km;
        best = i;
      }
    }
    this.applyCity(best);
    this.locAccuracy = accuracy;
    if (accuracy > 0) {
      this.locSource = '精确定位';
      this.locHint = '±' + Math.round(accuracy).toString() + ' m';
    } else {
      this.locSource = '城市级';
      this.locHint = '城市级 · 约 ' + Math.round(bestKm).toString() + ' km';
    }
  }

  private applyCity(i: number): void {
    // V2：ViewModel 自己 hold 状态，页面不再赋值
    this.vm.setCity(i);
  }

  /** 相册式交叉淡入：旧图垫底，新图从 0 淡到 1 */
  private crossFadeBg(next: number): void {
    if (next === this.bgIndex) return;
    this.bgPrev = this.bgIndex;
    this.bgIndex = next;
    this.bgFade = 0;
    animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.bgFade = 1;
    });
  }

  /** 分数 → 平滑 RGB（绿→黄绿→黄→橙→红） */
  private scoreRgb(v: number): number {
    const stops: number[] = [0, 20, 40, 60, 80, 100];
    const cols: number[] = [0xD8432E, 0xE8892B, 0xD9B62B, 0xA8C256, 0x4CAF50, 0x4CAF50];
    const t: number = Math.max(0, Math.min(100, v));
    let i: number = 0;
    while (i < stops.length - 2 && t > stops[i + 1]) i++;
    const span: number = stops[i + 1] - stops[i];
    const k: number = span <= 0 ? 0 : (t - stops[i]) / span;
    const c0: number = cols[i];
    const c1: number = cols[i + 1];
    const r: number = Math.round((c0 >> 16 & 0xFF) + ((c1 >> 16 & 0xFF) - (c0 >> 16 & 0xFF)) * k);
    const g: number = Math.round((c0 >> 8 & 0xFF) + ((c1 >> 8 & 0xFF) - (c0 >> 8 & 0xFF)) * k);
    const b: number = Math.round((c0 & 0xFF) + ((c1 & 0xFF) - (c0 & 0xFF)) * k);
    return (r << 16) | (g << 8) | b;
  }

  /** 评分 → 颜色（与表盘彩虹同语义：绿好红差） */
  private scoreColor(v: number, alpha: number): number {
    let rgb: number = 0x000000;
    if (v >= 80) rgb = 0x4CAF50;
    else if (v >= 60) rgb = 0xA8C256;
    else if (v >= 40) rgb = 0xD9B62B;
    else if (v >= 20) rgb = 0xE8892B;
    else rgb = 0xD8432E;
    return (alpha << 24) | rgb;
  }

  /** 有精确定位就用它，否则退回所选城市 */
  private myLat(): number {
    return this.userLat !== 0 ? this.userLat : this.vm.city.lat;
  }

  private myLon(): number {
    return this.userLon !== 0 ? this.userLon : this.vm.city.lon;
  }

  private centerOnMe(ctrl: map.MapComponentController): void {
    // 用 moveCamera 立即跳转；animateCamera(...,0) 在部分版本会被忽略
    try {
      ctrl.moveCamera(map.newLatLng({ latitude: this.myLat(), longitude: this.myLon() }, 9));
    } catch (e) {
      console.warn('center camera failed');
    }
    // 地图初始化可能异步覆盖镜头，200ms 后再确认一次
    setTimeout(() => {
      try {
        ctrl.moveCamera(map.newLatLng({ latitude: this.myLat(), longitude: this.myLon() }, 9));
      } catch (e) {
        console.warn('recenter failed');
      }
    }, 200);
  }

  /** 在地图上画 4×4 指数色块 */
  /** 按当前可见区域采样：范围跟着屏幕走，色场铺满全屏 */
  private async drawIndexGrid(ctrl: map.MapComponentController): Promise<void> {
    if (this.gridLoading) return;
    this.gridLoading = true;
    this.gridHint = '正在取预报…';
    try {
      const proj0: map.Projection = ctrl.getProjection();
      const region: mapCommon.VisibleRegion = proj0.getVisibleRegion();
      const lats: number[] = [region.farLeft.latitude, region.farRight.latitude,
        region.nearLeft.latitude, region.nearRight.latitude];
      const lons: number[] = [region.farLeft.longitude, region.farRight.longitude,
        region.nearLeft.longitude, region.nearRight.longitude];
      let latMin: number = lats[0];
      let latMax: number = lats[0];
      let lonMin: number = lons[0];
      let lonMax: number = lons[0];
      for (let i = 1; i < 4; i++) {
        latMin = Math.min(latMin, lats[i]);
        latMax = Math.max(latMax, lats[i]);
        lonMin = Math.min(lonMin, lons[i]);
        lonMax = Math.max(lonMax, lons[i]);
      }
      // 留 8% 余量，平移时不至于马上出现空白
      const padLat: number = (latMax - latMin) * 0.08;
      const padLon: number = (lonMax - lonMin) * 0.08;
      latMin -= padLat; latMax += padLat; lonMin -= padLon; lonMax += padLon;

      const centLat: number = (latMin + latMax) / 2;
      const centLon: number = (lonMin + lonMax) / 2;
      const spanKm: number = (latMax - latMin) * 111;
      this.lastSampleLat = centLat;
      this.lastSampleLon = centLon;
      this.lastSampleZoom = ctrl.getCameraPosition().zoom;
      this.lastSampleTs = Date.now();
      this.sampleCount = this.sampleCount + 1;

      const ctx: common.Context = getContext(this) as common.Context;
      const n: number = 8;
      const pts: GridPoint[] = await IndexGrid.buildBounds(ctx, latMin, latMax, lonMin, lonMax, n,
        this.vm.ymd);
      const okPts: GridPoint[] = pts.filter((g: GridPoint) => g.ok);
      console.info('NightWindow grid: total=' + pts.length.toString() + ' ok='
        + okPts.length.toString() + ' span=' + Math.round(spanKm).toString());
      if (pts.length === 0) {
        this.gridHint = '网络异常 · 稍后再试';
        return;
      }
      if (okPts.length === 0) {
        this.gridHint = '这一带取不到预报';
        return;
      }
      let sumScore: number = 0;
      for (const g of okPts) sumScore += g.score;
      const avg: number = sumScore / okPts.length;
      for (const g of pts) {
        if (!g.ok) { g.score = avg; g.ok = true; }
      }
      await ctrl.clear();
      const M: number = 40;
      const dense: GridPoint[] = IndexGrid.interpolate(pts, n, M);
      await this.paintField(ctrl, dense, M, centLat, centLon, latMax - latMin, lonMax - lonMin);
      this.gridHint = okPts.length.toString() + '/' + pts.length.toString() + ' 点';
    } catch (e) {
      const err = e as Error;
      console.error('NightWindow grid error: ' + err.message);
      this.gridHint = '取数失败';
    } finally {
      this.gridLoading = false;
    }
  }

  /** 用 Canvas 画连续色场：屏幕空间双线性插值，格子小到看不见 */
  private redrawField(): void {
    if (!this.canvasReady || this.mapCtl === null) return;
    if (this.mapW <= 0 || this.mapH <= 0) return;
    if (this.fieldPts.length < this.fieldN * this.fieldN) return;
    const c: CanvasRenderingContext2D = this.canvasCtx;
    c.clearRect(0, 0, vp2px(this.mapW), vp2px(this.mapH));

    const n: number = this.fieldN;
    const proj: map.Projection = this.mapCtl.getProjection();
    const sx: number[] = [];
    const sy: number[] = [];
    for (const g of this.fieldPts) {
      const p: mapCommon.MapPoint = proj.toScreenLocation({ latitude: g.lat, longitude: g.lon });
      sx.push(p.positionX);
      sy.push(p.positionY);
    }

    const K: number = 12;
    for (let i = 0; i < n - 1; i++) {
      for (let j = 0; j < n - 1; j++) {
        const id00: number = i * n + j;
        const id10: number = (i + 1) * n + j;
        const id01: number = i * n + j + 1;
        const id11: number = (i + 1) * n + j + 1;
        const s00: number = this.fieldPts[id00].score;
        const s10: number = this.fieldPts[id10].score;
        const s01: number = this.fieldPts[id01].score;
        const s11: number = this.fieldPts[id11].score;
        for (let u = 0; u < K; u++) {
          for (let v = 0; v < K; v++) {
            const tu: number = u / K;
            const tv: number = v / K;
            const tu2: number = (u + 1) / K;
            const tv2: number = (v + 1) / K;
            const x0: number = this.blend(sx[id00], sx[id10], sx[id01], sx[id11], tu, tv);
            const y0: number = this.blend(sy[id00], sy[id10], sy[id01], sy[id11], tu, tv);
            const x1: number = this.blend(sx[id00], sx[id10], sx[id01], sx[id11], tu2, tv2);
            const y1: number = this.blend(sy[id00], sy[id10], sy[id01], sy[id11], tu2, tv2);
            const sc: number = this.blend(s00, s10, s01, s11, (tu + tu2) / 2, (tv + tv2) / 2);
            const rgb: number = this.scoreRgb(sc);
            const r: number = (rgb >> 16) & 0xFF;
            const g: number = (rgb >> 8) & 0xFF;
            const b: number = rgb & 0xFF;
            c.fillStyle = 'rgb(' + r.toString() + ',' + g.toString() + ',' + b.toString() + ')';
            // 小格之间留 0.6vp 重叠，避免抗锯齿产生条纹
            c.fillRect(x0, y0, Math.max(1.6, x1 - x0 + 0.8), Math.max(1.6, y1 - y0 + 0.8));
          }
        }
      }
    }
  }

  /** 屏幕空间双线性插值 */
  private blend(a: number, b: number, cc: number, d: number, tu: number, tv: number): number {
    const top: number = a + (b - a) * tu;
    const bot: number = cc + (d - cc) * tu;
    return top + (bot - top) * tv;
  }

  /** 把密网格画成连续色场 */
  private async paintField(ctrl: map.MapComponentController, dense: GridPoint[], M: number,
    lat: number, lon: number, dLat: number, dLon: number): Promise<void> {
    const rowStep: number = M < dense.length
      ? Math.abs(dense[M].lat - dense[0].lat) : (dLat / (M - 1));
    const colStep: number = M > 1 ? Math.abs(dense[1].lon - dense[0].lon) : (dLon / (M - 1));
    const halfLat: number = rowStep * 0.5;
    const halfLon: number = colStep * 0.5;
    for (let i = 0; i < dense.length; i += 24) {
      const batch: GridPoint[] = dense.slice(i, i + 24);
      const jobs: Promise<void>[] = batch.map((g: GridPoint) => {
        const rr: number = Math.max(
          Math.abs(g.lat - lat) / (dLat / 2),
          Math.abs(g.lon - lon) / (dLon / 2));
        const a: number = Math.round(0xDC - 0xC4 * Math.min(1, rr));
        const opts: mapCommon.MapPolygonOptions = {
          points: [
            { latitude: g.lat - halfLat, longitude: g.lon - halfLon },
            { latitude: g.lat - halfLat, longitude: g.lon + halfLon },
            { latitude: g.lat + halfLat, longitude: g.lon + halfLon },
            { latitude: g.lat + halfLat, longitude: g.lon - halfLon }
          ],
          fillColor: (a << 24) | this.scoreRgb(g.score),
          strokeWidth: 0,
          zIndex: 5
        };
        return ctrl.addPolygon(opts).then(() => {}).catch(() => {});
      });
      await Promise.all(jobs);
    }
  }

  /** 世界视图：取城市点后用反距离加权铺成连续面 */
  private async buildWorldField(lat: number, lon: number, dLat: number, dLon: number,
    M: number): Promise<GridPoint[]> {
    const cities: ApiGridPoint[] = await ApiSource.world();
    if (cities.length < 4) return [];
    const seeds: GridPoint[] = [];
    for (const c of cities) {
      if (c.day === null) continue;
      const g: GridPoint = new GridPoint();
      g.lat = c.lat;
      g.lon = c.lon;
      g.bortle = 5;
      const r: ScoreResult = IndexGrid.scoreAt(c.day, c.lat, c.lon, 5, this.vm.ymd);
      g.score = r.total;
      g.ok = true;
      seeds.push(g);
    }
    if (seeds.length < 4) return [];

    const out: GridPoint[] = [];
    const latMin: number = lat - dLat / 2;
    const lonMin: number = lon - dLon / 2;
    for (let i = 0; i < M; i++) {
      for (let j = 0; j < M; j++) {
        const pLat: number = latMin + dLat * i / (M - 1);
        const pLon: number = lonMin + dLon * j / (M - 1);
        let num: number = 0;
        let den: number = 0;
        for (const sd of seeds) {
          const dx: number = (pLon - sd.lon) * Math.cos(pLat * Math.PI / 180);
          const dy: number = pLat - sd.lat;
          const d2: number = dx * dx + dy * dy + 0.5;
          const w: number = 1 / (d2 * d2);
          num += sd.score * w;
          den += w;
        }
        const g: GridPoint = new GridPoint();
        g.lat = pLat;
        g.lon = pLon;
        g.score = den > 0 ? num / den : 0;
        g.ok = true;
        out.push(g);
      }
    }
    return out;
  }

  /** 世界视图：按城市点着色（全球连续插值需要上万采样点，配额撑不住） */
  private async paintWorldDots(ctrl: map.MapComponentController): Promise<void> {
    const cities: ApiGridPoint[] = await ApiSource.world();
    if (cities.length === 0) {
      this.gridHint = '网络异常 · 稍后再试';
      return;
    }
    await ctrl.clear();
    let drawn: number = 0;
    for (let i = 0; i < cities.length; i += 12) {
      const batch: ApiGridPoint[] = cities.slice(i, i + 12);
      const jobs: Promise<void>[] = batch.map((c: ApiGridPoint) => {
        if (c.day === null) return Promise.resolve();
        const r: ScoreResult = IndexGrid.scoreAt(c.day, c.lat, c.lon, 5, this.vm.ymd);
        drawn++;
        const opts: mapCommon.MapCircleOptions = {
          center: { latitude: c.lat, longitude: c.lon },
          radius: 55000,
          fillColor: (0xC8 << 24) | this.scoreRgb(r.total),
          strokeWidth: 0,
          zIndex: 5
        };
        return ctrl.addCircle(opts).then(() => {}).catch(() => {});
      });
      await Promise.all(jobs);
    }
    this.gridHint = '全球 ' + drawn.toString() + ' 城';
  }

  /** 镜头停下后按需重采样（限频，保护配额） */
  private onCameraIdle(ctrl: map.MapComponentController): void {
    if (this.idleTimer > 0) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => { this.maybeResample(ctrl); }, 800);
  }

  private maybeResample(ctrl: map.MapComponentController): void {
    if (this.gridLoading) return;
    const pos: mapCommon.CameraPosition = ctrl.getCameraPosition();
    const spanKm: number = Math.max(150, Math.min(20000, 42000 / Math.pow(2, pos.zoom)));
    const moved: number = distanceKm(this.lastSampleLat, this.lastSampleLon,
      pos.target.latitude, pos.target.longitude);

    if (this.sampleCount > 0) {
      if (Date.now() - this.lastSampleTs < 15000) return;
      if (Math.abs(pos.zoom - this.lastSampleZoom) < 0.7 && moved < spanKm * 0.35) return;
      if (this.sampleCount >= 8) {
        this.gridHint = '本次已取样 8 次 · 重开地图可刷新';
        return;
      }
    }
    this.drawIndexGrid(ctrl);
  }

  /** 全国视图：17×17 采样 → 24×24 方块插值成连续色场 */
  private async drawNational(ctrl: map.MapComponentController, ctx: common.Context): Promise<void> {
    const N: number = 9;
    const pts: GridPoint[] = await IndexGrid.buildBounds(ctx, 18, 54, 74, 135, N, this.vm.ymd);
    this.gridPts = pts;
    const okPts: GridPoint[] = pts.filter((g: GridPoint) => g.ok);
    this.gridHint = '全国 ' + okPts.length.toString() + ' 点';

    if (okPts.length > 0) {
      // 取数失败的点用平均值补齐，否则会被当成 0 分渲染成大片红色
      let sumScore: number = 0;
      for (const g of okPts) sumScore += g.score;
      const avgScore: number = sumScore / okPts.length;
      for (const g of pts) {
        if (!g.ok) {
          g.score = avgScore;
          g.ok = true;
        }
      }
      const M: number = 30;
      const dense: GridPoint[] = IndexGrid.interpolate(pts, N, M);
      const halfLat: number = (54 - 18) / (N - 1) * 0.57;
      const halfLon: number = (135 - 74) / (N - 1) * 0.57;
      for (let i = 0; i < dense.length; i += 24) {
        const batch: GridPoint[] = dense.slice(i, i + 24);
        const jobs: Promise<void>[] = batch.map((g: GridPoint) => {
          const opts: mapCommon.MapPolygonOptions = {
            points: [
              { latitude: g.lat - halfLat, longitude: g.lon - halfLon },
              { latitude: g.lat - halfLat, longitude: g.lon + halfLon },
              { latitude: g.lat + halfLat, longitude: g.lon + halfLon },
              { latitude: g.lat + halfLat, longitude: g.lon - halfLon }
            ],
            fillColor: (0xB4 << 24) | this.scoreRgb(g.score),
            strokeWidth: 0,
            zIndex: 5
          };
          return ctrl.addPolygon(opts).then(() => {}).catch(() => {});
        });
        await Promise.all(jobs);
      }
    }
    try {
      // 按中国范围自动取景，别用固定 zoom 猜
      ctrl.animateCamera(map.newLatLngBounds({
        southwest: { latitude: 16, longitude: 72 },
        northeast: { latitude: 55, longitude: 137 }
      }, 24), 400);
    } catch (e) {
      console.warn('national camera failed');
    }
  }

  private openMap(): void {
    this.showSheet = false;
    if (this.darkHint === null) {
      // 没有暗夜提示时，就以当前城市为中心
      const g: LatLon = wgs84ToGcj02(this.vm.city.lat, this.vm.city.lon);
      this.markerLat = 0;
      this.markerLon = 0;
      this.mapOptions = {
        position: { target: { latitude: g.lat, longitude: g.lon }, zoom: 10 },
        dayNightMode: mapCommon.DayNightMode.NIGHT,
        myLocationControlsEnabled: true
      };
      this.showMap = true;
      return;
    }
    if (this.darkHint !== null) {
      // 计算用 WGS-84，展示用 GCJ-02
      const g: LatLon = wgs84ToGcj02(this.darkHint!.lat, this.darkHint!.lon);
      this.markerLat = g.lat;
      this.markerLon = g.lon;
      this.mapOptions = {
        position: {
          target: { latitude: g.lat, longitude: g.lon },
          zoom: 11
        },
        dayNightMode: mapCommon.DayNightMode.NIGHT,
        myLocationControlsEnabled: true
      };
    }
    this.showMap = true;
  }


  /** 每分钟走一次：更新时间，跨天了就重算并重取天气 */
  private tickMinute(): void {
    this.aboutToAppearClock();
    if (TonightViewModel.syncToday()) {
      console.info('NightWindow date rolled over, refreshing');
      this.vm.dateEpoch = this.vm.dateEpoch + 1;
      this.vm.refresh();
      this.loadWeather(true);
    }
  }

  aboutToAppearClock(): void {
    const d: Date = new Date();
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    this.clock = (h < 10 ? '0' : '') + h.toString() + ':' + (m < 10 ? '0' : '') + m.toString();
  }

  /** 重力感应：机身相对"静止姿态"的倾斜映射成 -1..1，做 parallax 3D */
  private bindTilt(): void {
    if (this.tiltBound) return;
    try {
      this.screenRot = display.getDefaultDisplaySync().rotation;
      sensor.on(sensor.SensorId.GRAVITY, (d: sensor.GravityResponse) => {
        if (!this.hasBase) {
          this.baseGX = d.x;
          this.baseGY = d.y;
          this.hasBase = true;
          return;
        }
        // 基线缓慢跟随，握持姿势变了也不会一直偏着
        this.baseGX = this.baseGX * 0.997 + d.x * 0.003;
        this.baseGY = this.baseGY * 0.997 + d.y * 0.003;

        const dx: number = d.x - this.baseGX;
        const dy: number = d.y - this.baseGY;

        // 按屏幕旋转把传感器坐标转到屏幕坐标
        let hx: number = dx;
        let vy: number = dy;
        if (this.screenRot === 1) {          // 横屏（左转）
          hx = dy; vy = -dx;
        } else if (this.screenRot === 3) {   // 横屏（右转）
          hx = -dy; vy = dx;
        } else if (this.screenRot === 2) {
          hx = -dx; vy = -dy;
        }

        const nx: number = Math.max(-1, Math.min(1, hx / 3.0));
        const ny: number = Math.max(-1, Math.min(1, vy / 3.0));
        // 低通滤波，避免手抖导致画面颤动
        this.tiltX = this.tiltX * 0.86 + nx * 0.14;
        this.tiltY = this.tiltY * 0.86 + ny * 0.14;

        if (this.tiltSamples < 3) {
          this.tiltSamples = this.tiltSamples + 1;
          console.info('NightWindow tilt rot=' + this.screenRot + ' raw=' + d.x.toFixed(2) + '/'
            + d.y.toFixed(2) + ' -> ' + this.tiltX.toFixed(2) + '/' + this.tiltY.toFixed(2));
        }
      }, { interval: 50000000 });
      this.tiltBound = true;
    } catch (e) {
      console.warn('tilt sensor unavailable');
    }
  }

  /** 读取窗口避让区，避免 ☰ / ◎ 压到挖孔或状态栏 */
  private async applySafeInsets(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      this.winRef = win;
      if (!this.insetsBound) {
        this.insetsBound = true;
        // 旋转/分屏后避让区会变，重新算一次
        win.on('windowSizeChange', () => { this.applySafeInsets(); });
      }
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cut: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      this.insetTop = px2vp(Math.max(sys.topRect.height, cut.topRect.height));
      this.insetLeft = px2vp(Math.max(sys.leftRect.width, cut.leftRect.width));
      this.insetRight = px2vp(Math.max(sys.rightRect.width, cut.rightRect.width));
      console.info('NightWindow insets top=' + this.insetTop + ' left=' + this.insetLeft
        + ' right=' + this.insetRight);
    } catch (e) {
      console.warn('applySafeInsets failed');
    }
  }

  aboutToAppear(): void {
    console.info('NightWindow material supported=' + uiMaterial.isImmersiveMaterialSupported()
      + ' level=' + uiMaterial.getGlobalMaterialLevel());
    this.vm.refresh();
    this.applySafeInsets();
    this.bindTilt();
    this.applyLearnedBias();
    this.flushFeedback();
    this.loadWeather(false);
    this.checkFeedback();
    this.loadSharePref();
    this.aboutToAppearClock();
    if (this.minuteTimer > 0) clearInterval(this.minuteTimer);
    this.minuteTimer = setInterval(() => { this.tickMinute(); }, 60000);
  }

  aboutToDisappear(): void {
    if (this.minuteTimer > 0) { clearInterval(this.minuteTimer); this.minuteTimer = -1; }
    if (this.camTimer > 0) { clearInterval(this.camTimer); this.camTimer = -1; }
  }

  build() {
    Stack() {
      // 星空图常驻垫底：两层交叉淡入，切换时像相册翻页
      Image(this.bgList[this.bgPrev])
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
        .blur(this.pageIndex === 0 ? 0 : 40)
        .scale({ x: 1.06, y: 1.06 })
        .translate({ x: this.tiltX * -10, y: this.tiltY * -10 })

      Image(this.bgList[this.bgIndex])
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
        .blur(this.pageIndex === 0 ? 0 : 40)
        .opacity(this.bgFade)
        .scale({ x: 1.06, y: 1.06 })
        .translate({ x: this.tiltX * -10, y: this.tiltY * -10 })

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 90, colors: this.sideVeil })

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: this.veilColors })

      // 顶部压暗：换到亮底图（如蟹状星云）时保证标题可读
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: this.topVeil })

      // 非首屏再加一层压暗，保证列表可读，同时保留模糊星空的氛围
      if (this.pageIndex !== 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#B3000000')
      }

      // 刷新提示 / 刷新中状态
      if (this.refreshHint.length > 0) {
        Row({ space: 6 }) {
          Text(this.refreshHint)
            .fontSize(12)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#66000000')
        .borderRadius(14)
        .position({ top: 100 + this.insetTop })
        .hitTestBehavior(HitTestMode.None)
      }

      Navigation() {
        Tabs({ barPosition: BarPosition.End, index: this.pageIndex }) {
        TabContent() {
          this.PosterPage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_moon'), '今夜')
          .labelStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' })
          .iconStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' }))

        TabContent() {
          this.WeekPage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_week'), '七天')
          .labelStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' })
          .iconStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' }))

        TabContent() {
          this.MinePage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_me'), '我的')
          .labelStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' })
          .iconStyle({ selectedColor: '#FFFFFF', unselectedColor: '#8C8C8C' }))
      }
      .scrollable(false)
      .barMode(BarMode.Fixed)
      .barHeight(56)
      .barBackgroundColor(Color.Transparent)
      .barOverlap(true)
      .barFloatingStyle({
        systemMaterial: this.glassThin,
        maskColor: Color.Transparent
      })
      .animationDuration(200)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        if (i === this.pageIndex) return;
        this.pageIndex = i;
        this.pgAlpha = 0;
        this.pgShiftX = 20;
        animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.pgAlpha = 1; });
        animateTo({ duration: 300, curve: curves.springMotion(0.5, 0.85) }, () => { this.pgShiftX = 0; });
      })
      }
      .hideBackButton(true)
      .hideToolBar(true)
      .title(this.TopBar())
      .titleMode(NavigationTitleMode.Mini)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')

      if (this.showMap) {
        Stack() {
          MapComponent({ mapOptions: this.mapOptions, mapCallback: this.mapCallback })
            .width('100%')
            .height('100%')

          // 左上：玻璃标题胶囊（官方那种模糊圆角）
          Text('观星指数 · ' + this.cityName2)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .borderWidth(0.5)
            .borderColor('#33FFFFFF')
            .position({ left: 20, top: 20 + this.insetTop })
            .hitTestBehavior(HitTestMode.None)

          // 右上：圆形关闭按钮，和地图自带控件同一种材质
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(13)
              .height(1.6)
              .borderRadius(1)
              .backgroundColor('#FFFFFF')
              .rotate({ angle: 45 })
            Column()
              .width(13)
              .height(1.6)
              .borderRadius(1)
              .backgroundColor('#FFFFFF')
              .rotate({ angle: -45 })
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .borderWidth(0.5)
          .borderColor('#33FFFFFF')
          .position({ right: 20, top: 20 + this.insetTop })
          .onClick(() => {
            if (this.camTimer > 0) { clearInterval(this.camTimer); this.camTimer = -1; }
            this.showMap = false;
          })

          // 左下：磨砂图例
          Column({ space: 6 }) {
            Text('观星指数').fontSize(10).fontColor('#B3B3B3')
            this.LegendRow('#4CAF50', '80+  极佳')
            this.LegendRow('#A8C256', '60–80  好')
            this.LegendRow('#D9B62B', '40–60  一般')
            this.LegendRow('#E8892B', '20–40  差')
            this.LegendRow('#D8432E', '<20  很差')
            if (this.gridHint.length > 0) {
              Text(this.gridHint).fontSize(9).fontColor('#8C8C8C').margin({ top: 4 })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .borderWidth(0.5)
          .borderColor('#26FFFFFF')
          .borderRadius(14)
          .position({ left: 20, bottom: 20 })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0A0A0A')
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.Friction })
            .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: 220, curve: Curve.Friction })),
          TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseIn })
        ))
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showMenu, this.MenuSheet(), {
      height: SheetSize.FIT_CONTENT,
      width: 560,
      dragBar: true,
      backgroundColor: Color.Transparent,
      showClose: false,
      preferType: SheetType.BOTTOM
    })
  }

  private mapCallback: (err: BusinessError, ctrl: map.MapComponentController) => void = (
    err: BusinessError, ctrl: map.MapComponentController) => {
    if (err) {
      this.mapError = 'code=' + err.code + ' ' + err.message;
      return;
    }
    this.mapError = '';
    this.mapCtl = ctrl;
    try {
      ctrl.setMyLocationEnabled(true);
    } catch (e) {
      console.warn('setMyLocationEnabled failed');
    }
    this.centerOnMe(ctrl);
    // 事件监听在部分设备上不触发，改用定时轮询镜头位置（2s 一次，开销可忽略）
    if (this.camTimer > 0) clearInterval(this.camTimer);
    this.camTimer = setInterval(() => { this.onCameraIdle(ctrl); }, 2000);
    this.drawIndexGrid(ctrl);
  }

  /** 落标记，并用官方接口校验本地转换结果 */
  private async dropMarker(ctrl: map.MapComponentController): Promise<void> {
    if (this.darkHint === null || this.markerLat === 0) return;

    // 用官方接口再算一遍，和本地结果对比（偏差应为 0）
    try {
      const official: mapCommon.LatLng = map.convertCoordinateSync(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: this.darkHint.lat, longitude: this.darkHint.lon });
      const dLat: number = Math.abs(official.latitude - this.markerLat);
      const dLon: number = Math.abs(official.longitude - this.markerLon);
      console.info('NightWindow coord diff: dLat=' + dLat.toFixed(6) + ' dLon=' + dLon.toFixed(6));
    } catch (e) {
      console.warn('convertCoordinateSync failed');
    }

    const opts: mapCommon.MarkerOptions = {
      position: { latitude: this.markerLat, longitude: this.markerLon },
      title: this.darkHint.name + ' · Bortle ' + this.darkHint.bortle.toString()
        + ' · ' + this.darkHint.km.toString() + ' km',
      clickable: true
    };
    try {
      await ctrl.addMarker(opts);
    } catch (e) {
      console.error('addMarker failed');
    }
  }

  @Builder
  DockItem(idx: number, label: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(this.pageIndex === idx ? '#FFFFFF' : '#8C8C8C')
        .fontWeight(this.pageIndex === idx ? FontWeight.Medium : FontWeight.Regular)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.pageIndex = idx; })
  }

  @Builder
  MinePage() {
    Column() {
      Text('我的')
        .fontSize(13)
        .fontColor('#CCCCCC')
        .width('100%')
        .padding({ left: 28, right: 28, top: 52, bottom: 16 })

      this.MineRow('地点', this.cityName2, () => { this.showCity = true; })
      this.MineRow('地图', '看暗夜地点', () => { this.openMap(); })
      this.MineRow('数据', '分数怎么来的', () => { this.showSheet = true; })
      this.MineRow('帮助改进观星指数', this.shareStats ? '匿名统计 · 开' : '匿名统计 · 关', () => {
        this.shareStats = !this.shareStats;
        this.toggleShare(this.shareStats);
      })
      this.MineRow('关于', '今夜星 v1.0.0', () => {})
      this.MineRow('开源协议', 'GPL-3.0 · 可商用，改后须开源', () => {})

      Blank()

      Text('新ICP备2026008516号-3A')
        .fontSize(10)
        .fontColor('#666666')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 4 })

      Text('源代码以 GPL-3.0 授权 · 背景图 CC BY 4.0')
        .fontSize(10)
        .fontColor('#4D4D4D')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 100 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .opacity(this.pageIndex === 2 ? this.pgAlpha : 1)
    .translate({ x: this.pageIndex === 2 ? this.pgShiftX : 0 })
    .padding({ bottom: 80 })
  }

  @Builder
  MineRow(title: string, value: string, action: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor('#FFFFFF')
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor('#999999')
      Text('›')
        .fontSize(13)
        .fontColor('#808080')
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 28, right: 28, top: 16, bottom: 16 })
    .onClick(action)
  }

  @Builder
  LegendRow(color: string, label: string) {
    Row({ space: 6 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(color)
      Text(label).fontSize(10).fontColor('#CCCCCC')
    }
  }

  @Builder
  RefreshHeader() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color('#FFFFFF')
      Text(this.refreshPrompt)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .textShadow({ radius: 8, color: '#B3000000' })
    }
    .height(52)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .clip(true)
  }

  @Builder
  NeedleTag(color: string, label: string) {
    Row({ space: 3 }) {
      Column()
        .width(5)
        .height(5)
        .borderRadius(3)
        .backgroundColor(color)
      Text(label)
        .fontSize(9)
        .fontColor('#B3B3B3')
        .textShadow({ radius: 8, color: '#B3000000' })
    }
  }

  @Builder
  Bar() {
    Column()
      .width(16)
      .height(1.6)
      .borderRadius(1)
      .backgroundColor('#FFFFFF')
  }

  @Builder
  TopBar() {
    Row() {
      // 用三条线画图标：字体里的 ☰ 有明显的字面偏移，几何绘制才能真居中
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: 4 }) {
          this.Bar()
          this.Bar()
          this.Bar()
        }
        .alignItems(HorizontalAlign.Center)
        // 系统材质容器内的可用区略有下移，补偿 2vp 使图标与圆完全同心
        .offset({ y: -2 })
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .systemMaterial(this.glassUltraThin)
      .onClick(() => { this.showMenu = true; })

      Blank()

      Column() {
        Text(this.cityName2)
          .fontSize(20)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)          .textShadow({ radius: 12, color: '#B3000000' })
        Text(this.vm.dateText + ' · ' + this.clock)
          .fontSize(11)
          .fontColor('#CCCCCC')          .textShadow({ radius: 10, color: '#B3000000' })
          .margin({ top: 2 })
      }
      .onClick(() => { this.showCity = true; })

      Blank()
    }
    .width('100%')
    .height(64 + this.insetTop)
    // 左右用同样的内边距，否则城市名会被推偏（左侧还要让开刘海）
    .padding({
      left: 20 + this.insetLeft,
      right: 20 + this.insetLeft,
      top: this.insetTop
    })
  }

  @Builder
  PosterPage() {
    Refresh({ refreshing: $$this.refreshing, builder: this.RefreshHeader() }) {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 内容
      Column() {
        Text(this.result.grade)
          .fontSize(30)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Regular)
          .textShadow({ radius: 14, color: '#000000', offsetY: 2 })

        Text('观星指数')
          .fontSize(13)
          .fontColor('#E6E6E6')          .textShadow({ radius: 10, color: '#B3000000' })
          .letterSpacing(1)
          .margin({ top: 4 })

        Row() {
          Text(this.result.total.toString())
            .fontSize(150)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Lighter)
            .letterSpacing(-6)
            .textShadow({ radius: 30, color: '#000000' })

          Text('/100')
            .fontSize(22)
            .fontColor('#CCCCCC')
            .textShadow({ radius: 10, color: '#B3000000' })
            .margin({ left: 8, bottom: 28 })

          // 压力表风格表盘：黑针今晚、红针昨晚
          Column({ space: 4 }) {
            ScoreGauge({ score: this.vm.result.total, refScore: this.vm.mwScore, gaugeSize: 100 })
            Row({ space: 8 }) {
              this.NeedleTag('#1A1A1A', '今晚')
              this.NeedleTag('#E0413A', '银河 ' + this.vm.mwScore.toString())
            }
          }
          .margin({ left: 20, bottom: 16 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 2 })

        Text(this.result.window === null ? '今晚没有观测窗口' : this.result.window.text)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .textShadow({ radius: 12, color: '#B3000000' })
          .margin({ top: 18 })

        Text(this.result.targetName + ' · ' + this.result.limit)
          .fontSize(12)
          .fontColor('#B3B3B3')
          .margin({ top: 6 })

        if (false) {
          Row({ space: 14 }) {
            Text('昨晚 少云 · 记一下？')
              .fontSize(12)
              .fontColor('#CCCCCC')
              .textShadow({ radius: 10, color: '#B3000000' })
            Text('全晴')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .onClick(() => { this.submitFeedback(0); })
            Text('少云')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .onClick(() => { this.submitFeedback(1); })
            Text('多云')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .onClick(() => { this.submitFeedback(2); })
            Text('阴')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .onClick(() => { this.submitFeedback(3); })
          }
          .margin({ top: 12 })
        }

        if (false && this.darkHint !== null) {
          Text('最近的暗夜　' + this.darkHint!.bearing + ' ' + this.darkHint!.km.toString()
            + ' km　' + this.darkHint!.name + '　Bortle ' + this.darkHint!.bortle.toString() + '　›')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .textShadow({ radius: 10, color: '#B3000000' })
            .margin({ top: 10 })
            .onClick(() => { this.openMap(); })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 28, right: 28, bottom: 108 })
      .constraintSize({ maxWidth: 560 })

      // 版权：贴在最右下角（不能在 Row 里，position 会相对 Row 计算）
      Text(this.bgCredit[this.bgIndex])
        .fontSize(9)
        .fontColor('#D9D9D9')
        .textAlign(TextAlign.End)
        .maxLines(2)
        .constraintSize({ maxWidth: 340 })
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(8)
        .backgroundColor('#40000000')
        .position({ right: 14, bottom: 12 })
        .hitTestBehavior(HitTestMode.None)

      // 信息入口
      Row({ space: 10 }) {
        Text('i')
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .borderWidth(0.5)
          .borderColor('#33FFFFFF')
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .onClick(() => { this.showSheet = true; })
      }
      .position({ right: 24, bottom: 86 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .opacity(this.pageIndex === 0 ? this.pgAlpha : 1)
    // 抵掉 Refresh 自带的下拉位移：只有加载动效被拉出来，画面本身不动
    .translate({ x: this.pageIndex === 0 ? this.pgShiftX : 0, y: -this.pullOffset })
    }
    .onRefreshing(() => { this.pullToRefresh(); })
    .onOffsetChange((v: number) => { this.pullOffset = px2vp(v); })
    .onStateChange((st: RefreshStatus) => {
      if (st === RefreshStatus.Drag) this.refreshPrompt = '下拉刷新';
      else if (st === RefreshStatus.OverDrag) this.refreshPrompt = '松手刷新';
      else if (st === RefreshStatus.Refresh) this.refreshPrompt = '正在刷新…';
    })
    .pullToRefresh(true)
    .gesture(
      PanGesture({ direction: PanDirection.Up, distance: 30 })
        .onActionEnd((e: GestureEvent) => {
          if (this.pageIndex !== 0) return;
          if (e.offsetY < -50) {
            this.pageIndex = 1;
          }
        })
    )
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 40 })
        .onActionEnd((e: GestureEvent) => {
          // 右滑 → 下一晚；左滑 → 上一晚；每换一晚换一张底图
          // 一次滑动可能触发多次 onActionEnd，做去抖
          const now: number = Date.now();
          if (Math.abs(e.offsetX) <= 60 || now - this.lastSwipeMs < 400) return;
          this.lastSwipeMs = now;
          if (e.offsetX > 0) {
            this.vm.changeNight(1);
            this.crossFadeBg((this.bgIndex + 1) % this.bgList.length);
          } else {
            this.vm.changeNight(-1);
            this.crossFadeBg((this.bgIndex - 1 + this.bgList.length) % this.bgList.length);
          }
        })
    )
    .bindSheet($$this.showCity, this.CitySheet(), {
      width: 560,
      showClose: false,
      preferType: SheetType.BOTTOM,
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: '#121212'
    })
  }

  @Builder
  MenuSheet() {
    Column() {
      Text('菜单')
        .fontSize(13)
        .fontColor('#999999')
        .width('100%')
        .padding({ bottom: 8 })

      this.MineRow('选择地点', this.cityName2, () => {
        this.showMenu = false;
        this.showCity = true;
      })
      this.MineRow('看暗夜地图', '', () => {
        this.showMenu = false;
        this.openMap();
      })
      this.MineRow('数据详情', '分数拆解', () => {
        this.showMenu = false;
        this.showSheet = true;
      })
      this.MineRow('使用我的位置', '', () => {
        this.showMenu = false;
        this.useMyLocation();
      })
    }
    .width('100%')
    .backgroundColor('#121212')
    .borderRadius(24)
    .padding({ left: 24, right: 24, top: 16, bottom: 28 })
    .margin({ bottom: 20 })
  }

  @Builder
  CitySheet() {
    Column() {
      Row() {
        Text(this.locating ? '定位中…' : '◎ 用我的位置')
          .fontSize(15)
          .fontColor('#FFFFFF')
        Blank()
        if (this.locHint.length > 0) {
          Text(this.locHint)
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 14 })
      .onClick(() => { this.useMyLocation(); })

      Divider().color('#33FFFFFF').margin({ bottom: 8 })

      ForEach(CITIES, (c: City, i: number) => {
        Row() {
          Column() {
            Text(c.name)
              .fontSize(16)
              .fontColor(this.vm.cityIndex === i ? '#FFFFFF' : '#FFFFFF')
            Text('Bortle ' + c.bortle.toString())
              .fontSize(11)
              .fontColor('#999999')
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          if (this.vm.cityIndex === i) {
            Text('●').fontSize(12).fontColor('#FFFFFF')
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.vm.setCity(i);
      this.loadWeather(false);
          this.showCity = false;
        })
      }, (c: City) => c.name)
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
  }

  @Builder
  WeekPage() {
    Column() {
      Column() {
        Text('七天')
          .fontSize(13)
          .fontColor('#CCCCCC')
        Text(this.vm.weekSummary)
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 28, right: 28, top: 52, bottom: 12 })

      List() {
        ForEach(this.weekRows, (row: DayScore) => {
          ListItem() {
            Row() {
              Column() {
                Text(row.label)
                  .fontSize(15)
                  .fontColor('#FFFFFF')
                Text(row.weekday)
                  .fontSize(11)
                  .fontColor('#B3B3B3')
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .width(90)

              Text(row.windowText)
                .fontSize(12)
                .fontColor('#E6E6E6')
                .layoutWeight(1)

              Text(row.total.toString())
                .fontSize(26)
                .fontColor(row.total >= 50 ? '#FFFFFF' : '#FFFFFF')
                .fontWeight(FontWeight.Lighter)
                .width(56)
                .textAlign(TextAlign.End)

              Text(row.grade)
                .fontSize(11)
                .fontColor('#B3B3B3')
                .width(40)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
          }
        }, (row: DayScore) => row.label)
      }
      .divider({ strokeWidth: 1, color: '#26FFFFFF', startMargin: 28, endMargin: 28 })
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: 72 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .opacity(this.pageIndex === 1 ? this.pgAlpha : 1)
    .translate({ x: this.pageIndex === 1 ? this.pgShiftX : 0 })
  }

  @Builder
  DataSheet() {
    Column() {
      // 窗口
      Row() {
        Text('今夜')
          .fontSize(12)
          .fontColor('#999999')
        Blank()
        Text(this.result.window === null ? '无窗口' : this.result.window.text)
          .fontSize(13)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .padding({ bottom: 14 })

      Divider().color('#33FFFFFF')

      // 综合分
      Row() {
        Column() {
          Text('综合分')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('天气分 × 天空分 ÷ 100')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.weather.toString() + ' × ' + this.result.sky.toString() + ' = ' + this.result.total.toString())
          .fontSize(15)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 14, bottom: 14 })

      Divider().color('#33FFFFFF')

      // 天气分
      Row() {
        Column() {
          Text('天气分 ' + this.result.weather.toString())
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('云 ' + this.result.cloud.toString() + ' · 通透 ' + this.result.transp.toString()
            + ' · 视宁 ' + this.result.seeing.toString() + ' · 露点 ' + this.result.dew.toString()
            + ' · 风 ' + this.result.wind.toString())
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      if (this.result.wet) {
        Text('今夜窗口内有降水，分数已置零')
          .fontSize(12)
          .fontColor('#FF6B6B')
          .width('100%')
          .padding({ top: 10, bottom: 10 })
        Divider().color('#33FFFFFF')
      }

      // 数据来源（B12）
      Row() {
        Column() {
          Text('数据来源')
            .fontSize(13)
            .fontColor('#CCCCCC')
          Text(this.vm.weatherOk
            ? (this.vm.weatherSource + (this.vm.weatherStale ? ' · 缓存' : '')
              + ' · ' + this.updatedClock())
            : '无预报 · 使用示例数据')
            .fontSize(11)
            .fontColor(this.vm.weatherOk ? '#999999' : '#CC8A3A')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#33FFFFFF')

      // 银河指数
      Row() {
        Column() {
          Text('银河指数 ' + this.vm.mwScore.toString())
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('高度 ' + Math.round(this.vm.mwParts.alt).toString() + '° ×'
            + ' 月光 ' + this.vm.mwParts.moonPart.toFixed(2) + ' ×'
            + ' 光污染 ' + this.vm.mwParts.bortlePart.toFixed(2) + ' ×'
            + ' 云 ' + this.vm.mwParts.cloudPart.toFixed(2))
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#33FFFFFF')

      // 天空分
      Row() {
        Column() {
          Text('天空分 ' + this.result.sky.toString())
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('Bortle ' + this.result.bortle.toString() + ' · 月光影响已计入')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.locSource.length > 0
          ? this.cityName2 + ' · ' + (this.locAccuracy > 0
              ? '±' + Math.round(this.locAccuracy).toString() + ' m'
              : '城市级')
          : this.cityName2)
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#33FFFFFF')

      // 月相
      Row() {
        Column() {
          Text('月亮')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('月龄 ' + this.result.moonAge.toFixed(1) + ' 天 · 照亮 '
            + Math.round(this.result.moonIllum * 100).toString() + '%')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.moonAltDeg > 0
          ? '高度 ' + Math.round(this.result.moonAltDeg).toString() + '°'
          : '已落下')
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#33FFFFFF')

      // 目标
      Row() {
        Column() {
          Text(this.result.targetName)
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('目标高度角 ' + Math.round(this.result.alt).toString() + '°')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.limit)
          .fontSize(12)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 28 })
  }

  private veilColors: Array<[ResourceColor, number]> = [
    ['#00000000', 0.58],
    ['#1F000000', 0.80],
    ['#52000000', 1.0]
  ];

  private topVeil: Array<[ResourceColor, number]> = [
    ['#40000000', 0.0],
    ['#00000000', 0.16]
  ];

  private sideVeil: Array<[ResourceColor, number]> = [
    ['#4D000000', 0.0],
    ['#1A000000', 0.20],
    ['#00000000', 0.38]
  ];
}
