import { GridPoint } from './IndexGrid';

/**
 * 全国观星点（省会 + 港澳台 + 几个著名暗夜地）。
 * 全国尺度下用「城市点」而不是连续色场：跨 500km 插值出来的平滑面是假精度。
 */
export class ChinaCity {
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

export const CHINA_CITIES: ChinaCity[] = [
  // 直辖市 / 省会
  new ChinaCity('北京', 39.90, 116.41, 9),
  new ChinaCity('天津', 39.13, 117.20, 9),
  new ChinaCity('石家庄', 38.04, 114.51, 8),
  new ChinaCity('太原', 37.87, 112.55, 8),
  new ChinaCity('呼和浩特', 40.84, 111.75, 8),
  new ChinaCity('沈阳', 41.81, 123.43, 8),
  new ChinaCity('长春', 43.82, 125.32, 8),
  new ChinaCity('哈尔滨', 45.80, 126.53, 8),
  new ChinaCity('上海', 31.23, 121.47, 9),
  new ChinaCity('南京', 32.06, 118.80, 9),
  new ChinaCity('杭州', 30.27, 120.15, 9),
  new ChinaCity('合肥', 31.82, 117.23, 8),
  new ChinaCity('福州', 26.07, 119.30, 8),
  new ChinaCity('南昌', 28.68, 115.86, 8),
  new ChinaCity('济南', 36.65, 117.12, 8),
  new ChinaCity('郑州', 34.75, 113.63, 8),
  new ChinaCity('武汉', 30.59, 114.31, 9),
  new ChinaCity('长沙', 28.23, 112.94, 8),
  new ChinaCity('广州', 23.13, 113.26, 9),
  new ChinaCity('南宁', 22.82, 108.37, 8),
  new ChinaCity('海口', 20.04, 110.32, 7),
  new ChinaCity('重庆', 29.56, 106.55, 8),
  new ChinaCity('成都', 30.67, 104.06, 8),
  new ChinaCity('贵阳', 26.65, 106.63, 7),
  new ChinaCity('昆明', 24.88, 102.83, 7),
  new ChinaCity('拉萨', 29.65, 91.14, 5),
  new ChinaCity('西安', 34.34, 108.94, 8),
  new ChinaCity('兰州', 36.06, 103.83, 7),
  new ChinaCity('西宁', 36.62, 101.78, 6),
  new ChinaCity('银川', 38.49, 106.23, 7),
  new ChinaCity('乌鲁木齐', 43.83, 87.62, 6),
  // 港澳台
  new ChinaCity('香港', 22.32, 114.17, 9),
  new ChinaCity('澳门', 22.20, 113.54, 9),
  new ChinaCity('台北', 25.03, 121.57, 9),
  new ChinaCity('台中', 24.15, 120.68, 8),
  new ChinaCity('高雄', 22.63, 120.30, 8),
  // 著名暗夜地
  new ChinaCity('冷湖', 38.75, 93.34, 1),
  new ChinaCity('阿里', 32.50, 80.10, 1),
  new ChinaCity('巴朗山', 30.87, 102.90, 2),
  new ChinaCity('兴隆站', 40.40, 117.57, 4)
];
