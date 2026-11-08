import { TonightViewModel, DayScore, CITIES } from '../viewmodel/TonightViewModel';
import { ScoreResult, City } from '../core/data/Models';
import { nearestDarkSite, DarkHint } from '../core/data/DarkSites';
import { FeedbackStore } from '../common/FeedbackStore';
import { common } from '@kit.AbilityKit';
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wgs84ToGcj02, LatLon, distanceKm } from '../core/geo/Coord';
import { geoLocationManager } from '@kit.LocationKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';

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
  @Local mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 30.67, longitude: 104.06 }, zoom: 10 },
    dayNightMode: mapCommon.DayNightMode.NIGHT
  };

  // —— 业务状态住在 ViewModel 里，这里只读 ——
  private vm: TonightViewModel = new TonightViewModel();
  private mapCtl: map.MapComponentController | null = null;

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
      await FeedbackStore.save(ctx, this.dateKey(d), v);
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

  aboutToAppear(): void {
    console.info('NightWindow material supported=' + uiMaterial.isImmersiveMaterialSupported()
      + ' level=' + uiMaterial.getGlobalMaterialLevel());
    this.vm.refresh();
    this.checkFeedback();
    this.aboutToAppearClock();
  }

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End, index: this.pageIndex }) {
        TabContent() {
          this.PosterPage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_moon'), '今夜')
          .labelStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' })
          .iconStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' }))

        TabContent() {
          this.WeekPage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_week'), '七天')
          .labelStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' })
          .iconStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' }))

        TabContent() {
          this.MinePage()
        }.tabBar(new BottomTabBarStyle($r('app.media.ic_me'), '我的')
          .labelStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' })
          .iconStyle({ selectedColor: '#F2ECE2', unselectedColor: '#7A7268' }))
      }
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
      .onChange((i: number) => { this.pageIndex = i; })

      if (this.showMap) {
        Column() {
          Row() {
            Text(this.darkHint === null ? this.cityName2 : this.darkHint!.name)
              .fontSize(15)
              .fontColor('#F2ECE2')
            Blank()
            Text('关闭')
              .fontSize(14)
              .fontColor('#D9A05B')
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
        .backgroundColor('#0B0A09')
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showMenu, this.MenuSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: '#14120F',
      showClose: true
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
        .fontColor(this.pageIndex === idx ? '#F2ECE2' : '#7A7268')
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
        .fontColor('#B9B2A6')
        .width('100%')
        .padding({ left: 28, right: 28, top: 52, bottom: 16 })

      this.MineRow('地点', this.cityName2, () => { this.showCity = true; })
      this.MineRow('地图', '看暗夜地点', () => { this.openMap(); })
      this.MineRow('数据', '分数怎么来的', () => { this.showSheet = true; })
      this.MineRow('关于', '今夜星 v1.0.0', () => {})

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0A09')
    .padding({ bottom: 80 })
  }

  @Builder
  MineRow(title: string, value: string, action: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor('#F2ECE2')
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor('#8C8378')
      Text('›')
        .fontSize(13)
        .fontColor('#6B645B')
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 28, right: 28, top: 16, bottom: 16 })
    .onClick(action)
  }

  @Builder
  PosterPage() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 背景图
      Image($r('app.media.bg_pillars'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)

      // 遮罩一：左侧压暗（横屏时保证左下可读）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: this.sideVeil
        })

      // 遮罩二：自下而上压暗
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: this.veilColors
        })

      // 顶部：时间 + 地点
      Column() {
        Row() {
          Text('☰')
            .fontSize(16)
            .fontColor('#F2ECE2')
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .borderRadius(20)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
            .borderWidth(0.5)
            .borderColor('#33FFFFFF')
            .onClick(() => { this.showMenu = true; })

          Blank()

          Text('◎')
            .fontSize(16)
            .fontColor('#F2ECE2')
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .borderRadius(20)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
            .borderWidth(0.5)
            .borderColor('#33FFFFFF')
            .onClick(() => { this.useMyLocation(); })
        }
        .width('100%')
        .padding({ left: 28, right: 28 })

        Column() {
          Text(this.cityName2)
            .fontSize(22)
            .fontColor('#F2ECE2')
            .fontWeight(FontWeight.Medium)
          Text(this.dateText + ' · ' + this.clock)
            .fontSize(11)
            .fontColor('#B9B2A6')
            .margin({ top: 3 })
        }
        .margin({ top: 6 })
        .onClick(() => { this.showCity = true; })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .position({ x: 0, y: 0 })
      .padding({ top: 18 })

      // 内容
      Column() {
        Text(this.result.grade)
          .fontSize(30)
          .fontColor('#F2ECE2')
          .fontWeight(FontWeight.Regular)
          .textShadow({ radius: 14, color: '#000000', offsetY: 2 })

        Text('观星指数')
          .fontSize(13)
          .fontColor('#D6CFC2')
          .letterSpacing(1)
          .margin({ top: 4 })

        Row() {
          Text(this.result.total.toString())
            .fontSize(150)
            .fontColor('#F2ECE2')
            .fontWeight(FontWeight.Lighter)
            .letterSpacing(-6)
            .textShadow({ radius: 30, color: '#000000' })

          Text('/100')
            .fontSize(22)
            .fontColor('#B9B2A6')
            .margin({ left: 8, bottom: 28 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 2 })

        Text(this.result.window === null ? '今晚没有观测窗口' : this.result.window.text)
          .fontSize(15)
          .fontColor('#E9E3D9')
          .margin({ top: 18 })

        Text(this.result.targetName + ' · ' + this.result.limit)
          .fontSize(12)
          .fontColor('#9A9186')
          .margin({ top: 6 })

        if (this.showFeedback) {
          Row({ space: 14 }) {
            Text('昨晚 少云 · 记一下？')
              .fontSize(12)
              .fontColor('#B9B2A6')
            Text('全晴')
              .fontSize(12)
              .fontColor('#D9A05B')
              .onClick(() => { this.submitFeedback(0); })
            Text('少云')
              .fontSize(12)
              .fontColor('#D9A05B')
              .onClick(() => { this.submitFeedback(1); })
            Text('多云')
              .fontSize(12)
              .fontColor('#D9A05B')
              .onClick(() => { this.submitFeedback(2); })
            Text('阴')
              .fontSize(12)
              .fontColor('#D9A05B')
              .onClick(() => { this.submitFeedback(3); })
          }
          .margin({ top: 12 })
        }

        if (this.result.total < 30 && this.darkHint !== null) {
          Text('最近的暗夜　' + this.darkHint!.bearing + ' ' + this.darkHint!.km.toString()
            + ' km　' + this.darkHint!.name + '　Bortle ' + this.darkHint!.bortle.toString() + '　›')
            .fontSize(12)
            .fontColor('#D9A05B')
            .margin({ top: 10 })
            .onClick(() => { this.openMap(); })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 28, right: 28, bottom: 108 })
      .constraintSize({ maxWidth: 560 })

      // 信息入口
      Row({ space: 10 }) {
        Text('地图')
          .width(46)
          .height(32)
          .borderRadius(16)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .borderWidth(0.5)
          .borderColor('#33FFFFFF')
          .textAlign(TextAlign.Center)
          .fontSize(12)
          .fontColor('#E8E2D6')
          .onClick(() => { this.openMap(); })

        Text('i')
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .borderWidth(0.5)
          .borderColor('#33FFFFFF')
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor('#E8E2D6')
          .onClick(() => { this.showSheet = true; })
      }
      .position({ right: 24, bottom: 86 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0A09')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 30 })
        .onActionEnd((e: GestureEvent) => {
          if (e.offsetY < -50 && this.pageIndex === 0) {
            this.pageIndex = 1;
          }
        })
    )
    .bindSheet($$this.showCity, this.CitySheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: '#14120F'
    })
  }

  @Builder
  MenuSheet() {
    Column() {
      Text('菜单')
        .fontSize(13)
        .fontColor('#8C8378')
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
    .padding({ left: 20, right: 20, bottom: 24 })
  }

  @Builder
  CitySheet() {
    Column() {
      Row() {
        Text(this.locating ? '定位中…' : '◎ 用我的位置')
          .fontSize(15)
          .fontColor('#D9A05B')
        Blank()
        if (this.locHint.length > 0) {
          Text(this.locHint)
            .fontSize(11)
            .fontColor('#8C8378')
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 14 })
      .onClick(() => { this.useMyLocation(); })

      Divider().color('#2A2620').margin({ bottom: 8 })

      ForEach(CITIES, (c: City, i: number) => {
        Row() {
          Column() {
            Text(c.name)
              .fontSize(16)
              .fontColor(this.vm.cityIndex === i ? '#D9A05B' : '#F2ECE2')
            Text('Bortle ' + c.bortle.toString())
              .fontSize(11)
              .fontColor('#8C8378')
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          if (this.vm.cityIndex === i) {
            Text('●').fontSize(12).fontColor('#D9A05B')
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.vm.setCity(i);
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
          .fontColor('#B9B2A6')
        Text(this.vm.weekSummary)
          .fontSize(12)
          .fontColor('#8C8378')
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
                  .fontColor('#F2ECE2')
                Text(row.weekday)
                  .fontSize(11)
                  .fontColor('#9A9186')
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .width(90)

              Text(row.windowText)
                .fontSize(12)
                .fontColor('#CFC7BA')
                .layoutWeight(1)

              Text(row.total.toString())
                .fontSize(26)
                .fontColor(row.total >= 50 ? '#D9A05B' : '#F2ECE2')
                .fontWeight(FontWeight.Lighter)
                .width(56)
                .textAlign(TextAlign.End)

              Text(row.grade)
                .fontSize(11)
                .fontColor('#9A9186')
                .width(40)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
          }
        }, (row: DayScore) => row.label)
      }
      .divider({ strokeWidth: 1, color: '#1E1B17', startMargin: 28, endMargin: 28 })
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: 72 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0A09')
  }

  @Builder
  DataSheet() {
    Column() {
      // 窗口
      Row() {
        Text('今夜')
          .fontSize(12)
          .fontColor('#8C8378')
        Blank()
        Text(this.result.window === null ? '无窗口' : this.result.window.text)
          .fontSize(13)
          .fontColor('#E9E3D9')
      }
      .width('100%')
      .padding({ bottom: 14 })

      Divider().color('#2A2620')

      // 综合分
      Row() {
        Column() {
          Text('综合分')
            .fontSize(16)
            .fontColor('#F2ECE2')
          Text('天气分 × 天空分 ÷ 100')
            .fontSize(11)
            .fontColor('#8C8378')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.weather.toString() + ' × ' + this.result.sky.toString() + ' = ' + this.result.total.toString())
          .fontSize(15)
          .fontColor('#D9A05B')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 14, bottom: 14 })

      Divider().color('#2A2620')

      // 天气分
      Row() {
        Column() {
          Text('天气分 ' + this.result.weather.toString())
            .fontSize(16)
            .fontColor('#F2ECE2')
          Text('云 ' + this.result.cloud.toString() + ' · 通透 ' + this.result.transp.toString()
            + ' · 视宁 ' + this.result.seeing.toString() + ' · 露点 ' + this.result.dew.toString())
            .fontSize(11)
            .fontColor('#8C8378')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#2A2620')

      // 天空分
      Row() {
        Column() {
          Text('天空分 ' + this.result.sky.toString())
            .fontSize(16)
            .fontColor('#F2ECE2')
          Text('Bortle ' + this.result.bortle.toString() + ' · 月光影响已计入')
            .fontSize(11)
            .fontColor('#8C8378')
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
          .fontColor('#8C8378')
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#2A2620')

      // 月相
      Row() {
        Column() {
          Text('月亮')
            .fontSize(16)
            .fontColor('#F2ECE2')
          Text('月龄 ' + this.result.moonAge.toFixed(1) + ' 天 · 照亮 '
            + Math.round(this.result.moonIllum * 100).toString() + '%')
            .fontSize(11)
            .fontColor('#8C8378')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.moonAltDeg > 0
          ? '高度 ' + Math.round(this.result.moonAltDeg).toString() + '°'
          : '已落下')
          .fontSize(12)
          .fontColor('#8C8378')
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })

      Divider().color('#2A2620')

      // 目标
      Row() {
        Column() {
          Text(this.result.targetName)
            .fontSize(16)
            .fontColor('#F2ECE2')
          Text('目标高度角 ' + Math.round(this.result.alt).toString() + '°')
            .fontSize(11)
            .fontColor('#8C8378')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.result.limit)
          .fontSize(12)
          .fontColor('#D9A05B')
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 28 })
  }

  private veilColors: Array<[ResourceColor, number]> = [
    ['#000B0A09', 0.0],
    ['#100B0A09', 0.22],
    ['#480B0A09', 0.44],
    ['#B80B0A09', 0.66],
    ['#F20B0A09', 0.86],
    ['#FF0B0A09', 1.0]
  ];

  private sideVeil: Array<[ResourceColor, number]> = [
    ['#880B0A09', 0.0],
    ['#440B0A09', 0.24],
    ['#0A0B0A09', 0.44],
    ['#000B0A09', 0.58]
  ];
}
