import { TonightViewModel, DayScore, CITIES } from '../viewmodel/TonightViewModel';
import { ScoreResult, City } from '../core/data/Models';
import { nearestDarkSite, DarkHint } from '../core/data/DarkSites';
import { FeedbackStore } from '../common/FeedbackStore';
import { setCloudBias } from '../core/score/Score';
import { FeedbackUploader } from '../common/FeedbackUploader';
import { WeatherRepo } from '../core/weather/WeatherRepo';
import { WeatherBundle } from '../core/weather/WeatherTypes';
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
        Column() {
          Row() {
            Text(this.darkHint === null ? this.cityName2 : this.darkHint!.name)
              .fontSize(15)
              .fontColor('#FFFFFF')
            Blank()
            Text('关闭')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .onClick(() => { this.showMap = false; })
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 18, bottom: 14 })

          MapComponent({ mapOptions: this.mapOptions, mapCallback: this.mapCallback })
            .layoutWeight(1)
            .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0A0A0A')
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
    this.dropMarker(ctrl);
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

      Blank()

      Text('新ICP备2026008516号-3A')
        .fontSize(10)
        .fontColor('#666666')
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
    .padding({
      left: 20 + this.insetLeft,
      right: 20 + this.insetRight,
      top: this.insetTop
    })
  }

  @Builder
  PosterPage() {
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
          ScoreGauge({ score: this.vm.result.total, refScore: this.vm.refScore, gaugeSize: 100 })
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

      // 信息入口
      Row({ space: 10 }) {
        Text(this.bgCredit[this.bgIndex])
          .fontSize(9)
          .fontColor('#D9D9D9')
          .textShadow({ radius: 8, color: '#B3000000' })
          .textAlign(TextAlign.End)
          .maxLines(2)
          .constraintSize({ maxWidth: 320 })
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(8)
          .backgroundColor('#40000000')
          .position({ right: 24, bottom: 126 })
          .hitTestBehavior(HitTestMode.None)

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
    .translate({ x: this.pageIndex === 0 ? this.pgShiftX : 0 })
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 30 })
        .onActionEnd((e: GestureEvent) => {
          if (e.offsetY < -50 && this.pageIndex === 0) {
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
