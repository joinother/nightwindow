import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

/**
 * 本地反馈存储：{ 'YYYY-MM-DD': '0'|'1'|'2'|'3'|'4' }
 * 0 全晴 1 少云 2 多云 3 阴 4 没出去
 */
/** 一条待上报的反馈 */
export class FeedbackRecord {
  dateKey: string = '';
  value: number = 0;      // 0 全晴 1 少云 2 多云 3 阴 4 没出去
  predicted: number = -1; // 当时的预报云量
  ts: number = 0;
}

export class FeedbackStore {
  private static readonly NAME: string = 'feedback';
  private static readonly KEY: string = 'records';

  private static async open(ctx: common.Context): Promise<preferences.Preferences> {
    return await preferences.getPreferences(ctx, FeedbackStore.NAME);
  }

  private static async readAll(ctx: common.Context): Promise<Record<string, string>> {
    const p: preferences.Preferences = await FeedbackStore.open(ctx);
    const raw: string = p.getSync(FeedbackStore.KEY, '{}') as string;
    try {
      return JSON.parse(raw) as Record<string, string>;
    } catch (e) {
      return {};
    }
  }

  /** 待上报的记录（批量上报用） */
  static async pending(ctx: common.Context): Promise<FeedbackRecord[]> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    const out: FeedbackRecord[] = [];
    for (const k of Object.keys(all)) {
      const parts: string[] = all[k].split('|');
      const uploaded: string = parts.length > 2 ? parts[2] : '0';
      if (uploaded === '1') continue;
      const r: FeedbackRecord = new FeedbackRecord();
      r.dateKey = k;
      r.value = Number(parts[0]);
      r.predicted = parts.length > 1 ? Number(parts[1]) : -1;
      r.ts = parts.length > 3 ? Number(parts[3]) : 0;
      out.push(r);
    }
    return out;
  }

  /** 标记为已上传 */
  static async markUploaded(ctx: common.Context, keys: string[]): Promise<void> {
    if (keys.length === 0) return;
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    for (const k of keys) {
      const parts: string[] = (all[k] ?? '').split('|');
      if (parts.length < 2) continue;
      all[k] = parts[0] + '|' + parts[1] + '|1|' + (parts.length > 3 ? parts[3] : '0');
    }
    const p: preferences.Preferences = await FeedbackStore.open(ctx);
    await p.put(FeedbackStore.KEY, JSON.stringify(all));
    await p.flush();
  }

  static async has(ctx: common.Context, dateKey: string): Promise<boolean> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    return all[dateKey] !== undefined;
  }

  /** 各档对应的实际云量中值（用于校准） */
  private static readonly OBS_CLOUD: number[] = [5, 25, 55, 90];

  /** 存反馈，同时记下当时的预报云量，供日后校准 */
  /**
   * 从历史反馈学出「预报云量偏差」：正数=预报偏少，负数=预报偏多。
   * 样本不足 3 条返回 0，不做校正。
   */
  static async cloudBias(ctx: common.Context): Promise<number> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    let diff: number = 0;
    let n: number = 0;
    for (const k of Object.keys(all)) {
      const parts: string[] = all[k].split('|');
      const v: number = Number(parts[0]);
      const p: number = parts.length > 1 ? Number(parts[1]) : -1;
      if (v < 0 || v > 3 || p < 0) continue;
      diff += FeedbackStore.OBS_CLOUD[v] - p;
      n++;
    }
    if (n < 3) return 0;
    return Math.max(-20, Math.min(20, diff / n));
  }

  static async save(ctx: common.Context, dateKey: string, value: number,
    predicted: number = -1): Promise<void> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    // 格式：值|预报云量|已上传(0/1)|时间戳
    all[dateKey] = value.toString() + '|' + Math.round(predicted).toString()
      + '|0|' + Date.now().toString();
    const p: preferences.Preferences = await FeedbackStore.open(ctx);
    await p.put(FeedbackStore.KEY, JSON.stringify(all));
    await p.flush();
    Logger.info('feedback saved: ' + dateKey + ' = ' + value.toString());
  }
}
