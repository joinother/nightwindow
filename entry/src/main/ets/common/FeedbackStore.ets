import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

/**
 * 本地反馈存储：{ 'YYYY-MM-DD': '0'|'1'|'2'|'3'|'4' }
 * 0 全晴 1 少云 2 多云 3 阴 4 没出去
 */
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

  static async has(ctx: common.Context, dateKey: string): Promise<boolean> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    return all[dateKey] !== undefined;
  }

  static async save(ctx: common.Context, dateKey: string, value: number): Promise<void> {
    const all: Record<string, string> = await FeedbackStore.readAll(ctx);
    all[dateKey] = value.toString();
    const p: preferences.Preferences = await FeedbackStore.open(ctx);
    await p.put(FeedbackStore.KEY, JSON.stringify(all));
    await p.flush();
    Logger.info('feedback saved: ' + dateKey + ' = ' + value.toString());
  }
}
