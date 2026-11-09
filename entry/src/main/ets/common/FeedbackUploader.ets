import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { FeedbackRecord, FeedbackStore } from './FeedbackStore';
import { Logger } from './Logger';

/**
 * 反馈批量上报（设计文档 6.6.7）
 *
 * 隐私边界：无用户 ID、无设备 ID、坐标粗化到 0.1°、服务端不落 IP、攒够批量再发。
 * 端点未部署时保持静默，记录留在本地队列里，不会丢。
 */
export class FeedbackUploader {
  /** 服务端地址；部署后填这里即可，例如 https://api.example.com/v1/feedback */
  private static readonly ENDPOINT: string = '';
  private static readonly SHARE_KEY: string = 'shareStats';

  /** 用户是否允许匿名统计（默认开，符合“匿名统计只需告知”的口径） */
  static async shareEnabled(ctx: common.Context): Promise<boolean> {
    const p: preferences.Preferences = await preferences.getPreferences(ctx, 'feedback');
    return p.getSync(FeedbackUploader.SHARE_KEY, true) as boolean;
  }

  static async setShare(ctx: common.Context, on: boolean): Promise<void> {
    const p: preferences.Preferences = await preferences.getPreferences(ctx, 'feedback');
    await p.put(FeedbackUploader.SHARE_KEY, on);
    await p.flush();
  }

  /** 坐标粗化到 0.1°，约 11 km */
  private static grid(v: number): string {
    return (Math.round(v * 10) / 10).toFixed(1);
  }

  /**
   * 尝试批量上报。返回成功上报的条数。
   * 端点为空、用户关闭、无网络时都静默返回 0。
   */
  static async flush(ctx: common.Context, lat: number, lon: number, version: string): Promise<number> {
    if (FeedbackUploader.ENDPOINT.length === 0) return 0;
    if (!(await FeedbackUploader.shareEnabled(ctx))) return 0;

    const queue: FeedbackRecord[] = await FeedbackStore.pending(ctx);
    if (queue.length === 0) return 0;
    // 只上报真正观测过的（4 = 没出去，不参与算法改进）
    const usable: FeedbackRecord[] = queue.filter((r: FeedbackRecord) => r.value >= 0 && r.value <= 3);
    if (usable.length === 0) return 0;

    const items: Record<string, string | number>[] = usable.map((r: FeedbackRecord) => {
      const item: Record<string, string | number> = {
        'city_grid': FeedbackUploader.grid(lat) + ',' + FeedbackUploader.grid(lon),
        'date': r.dateKey,
        'predicted': r.predicted,
        'actual': r.value,
        'ver': version
      };
      return item;
    });

    try {
      const req: http.HttpRequest = http.createHttp();
      const res: http.HttpResponse = await req.request(FeedbackUploader.ENDPOINT, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ items: items }),
        connectTimeout: 8000,
        readTimeout: 8000
      });
      req.destroy();
      if (res.responseCode >= 200 && res.responseCode < 300) {
        const keys: string[] = usable.map((r: FeedbackRecord) => r.dateKey);
        await FeedbackStore.markUploaded(ctx, keys);
        Logger.info('feedback uploaded: ' + keys.length.toString());
        return keys.length;
      }
      Logger.info('feedback upload rejected: ' + res.responseCode.toString());
    } catch (e) {
      // 离线是常态，不打扰用户
    }
    return 0;
  }
}
