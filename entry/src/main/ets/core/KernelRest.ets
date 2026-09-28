/**
 * M2 · 内核 REST 数据面客户端（主进程 → 扩展内核 127.0.0.1:9096）
 *
 * 跨进程 loopback 已在 T3 实证可达（主进程自检 ext-kernel OK）。
 * 覆盖：/version 存活、/proxies 节点与策略组、/proxies/{name}/delay 测速、PUT /proxies/{group} 切换。
 */
import httpRequest from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KernelDelayResp, KernelProxiesResp, KernelVersionResp } from '../model/Types';

const DOMAIN = 0x0000;
const TAG = 'KernelRest';
const BASE = 'http://127.0.0.1:9096';
const DEFAULT_TEST_URL = 'http://www.gstatic.com/generate_204';
const CONNECT_TIMEOUT = 5000;

function destroySafe(http: httpRequest.HttpRequest): void {
  try {
    http.destroy();
  } catch (e) {
    // ignore
  }
}

export class KernelRest {
  /** /version：返回版本串；失败返回空串 */
  static async version(): Promise<string> {
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request(`${BASE}/version`, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: CONNECT_TIMEOUT
      });
      destroySafe(http);
      if (resp.responseCode !== 200) {
        return '';
      }
      const body = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      const parsed = JSON.parse(body) as KernelVersionResp;
      const v = parsed.version;
      return v === undefined || v === '' ? body.slice(0, 40) : v;
    } catch (e) {
      destroySafe(http);
      return '';
    }
  }

  static async isAlive(): Promise<boolean> {
    const v = await KernelRest.version();
    return v !== '';
  }

  /** /proxies：节点与策略组全量视图（失败返回 null） */
  static async proxies(): Promise<KernelProxiesResp | null> {
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request(`${BASE}/proxies`, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: CONNECT_TIMEOUT
      });
      destroySafe(http);
      if (resp.responseCode !== 200) {
        return null;
      }
      const body = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      return JSON.parse(body) as KernelProxiesResp;
    } catch (e) {
      destroySafe(http);
      return null;
    }
  }

  /** /proxies/{name}/delay：返回延迟毫秒；失败/超时返回 -1 */
  static async delay(name: string, timeoutMs: number, testUrl: string): Promise<number> {
    const url = testUrl !== '' ? testUrl : DEFAULT_TEST_URL;
    const target = `${BASE}/proxies/${encodeURIComponent(name)}/delay`
      + `?timeout=${timeoutMs}&url=${encodeURIComponent(url)}`;
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request(target, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: timeoutMs + 3000,
        readTimeout: timeoutMs + 3000
      });
      destroySafe(http);
      const body = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      if (resp.responseCode !== 200) {
        hilog.info(DOMAIN, TAG, 'delay(%{public}s) code=%{public}d body=%{public}s',
          name, resp.responseCode, body.slice(0, 120));
        return -1;
      }
      const parsed = JSON.parse(body) as KernelDelayResp;
      const d = parsed.delay;
      return d !== undefined && Number.isFinite(d) && d > 0 ? d : -1;
    } catch (e) {
      destroySafe(http);
      const err = e as BusinessError;
      hilog.info(DOMAIN, TAG, 'delay(%{public}s) 失败 code=%{public}d msg=%{public}s', name, err.code, err.message);
      return -1;
    }
  }

  /** PUT /proxies/{group}：切换策略组选中节点 */
  static async select(group: string, node: string): Promise<boolean> {
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request(`${BASE}/proxies/${encodeURIComponent(group)}`, {
        method: httpRequest.RequestMethod.PUT,
        header: { 'Content-Type': 'application/json' },
        extraData: `{"name":${JSON.stringify(node)}}`,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: CONNECT_TIMEOUT
      });
      destroySafe(http);
      if (resp.responseCode === 204 || resp.responseCode === 200) {
        return true;
      }
      const body = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      hilog.warn(DOMAIN, TAG, 'select(%{public}s→%{public}s) code=%{public}d body=%{public}s',
        group, node, resp.responseCode, body.slice(0, 120));
      return false;
    } catch (e) {
      destroySafe(http);
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'select 失败 code=%{public}d msg=%{public}s', err.code, err.message);
      return false;
    }
  }
}