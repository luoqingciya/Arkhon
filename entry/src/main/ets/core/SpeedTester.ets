/**
 * M2 · 节点测速：并发（6 路分片）+ 结果写回档案延迟缓存
 */
import { KernelRest } from './KernelRest';
import { ProfileStore } from './ProfileStore';
import { TunnelManager } from './TunnelManager';
import { DelayEntry, ProxyNode } from '../model/Types';

const CONCURRENCY = 6;
const TIMEOUT_MS = 5000;
const TEST_URL = 'http://www.gstatic.com/generate_204';

export class SpeedTester {
  static running: boolean = false;

  /** 全量测速：返回已测节点数（并发分片；进度经 onProgress 逐节点回调） */
  static async testAll(profileId: string, nodes: ProxyNode[],
    onProgress: (name: string, delay: number) => void): Promise<number> {
    if (SpeedTester.running || nodes.length === 0) {
      return 0;
    }
    SpeedTester.running = true;
    const results: Record<string, DelayEntry> = ProfileStore.delayMap(profileId);
    const lanes: Promise<void>[] = [];
    const width = Math.min(CONCURRENCY, nodes.length);
    for (let i = 0; i < width; i++) {
      lanes.push(SpeedTester.lane(i, nodes, results, onProgress));
    }
    try {
      await Promise.all(lanes);
    } catch (e) {
      // 单节点异常已在 KernelRest 内兜底为 -1，这里保底
    }
    ProfileStore.setDelays(profileId, results);
    SpeedTester.running = false;
    return nodes.length;
  }

  private static async lane(start: number, nodes: ProxyNode[], results: Record<string, DelayEntry>,
    onProgress: (name: string, delay: number) => void): Promise<void> {
    for (let i = start; i < nodes.length; i += CONCURRENCY) {
      const node = nodes[i];
      const delay = await KernelRest.delay(node.name, TIMEOUT_MS, TEST_URL);
      const entry: DelayEntry = { delay: delay, at: Date.now() };
      results[node.name] = entry;
      onProgress(node.name, delay);
      // 逐节点落日志（成功也记）：出问题时能区分「节点不可达」与「仅某站点不可达」
      TunnelManager.log(`[测速] ${node.name} → ${delay > 0 ? `${delay} ms` : '超时/失败'}`);
    }
  }
}