/**
 * 保活基线工具：长时任务 + 常驻通知 + 回收检测
 *
 * 接线（M2 起）：由 core/TunnelManager 随隧道生命周期统筹——
 *  - 隧道建链成功 → start；断开 → stop；热重载/重建 → refresh（避免重复申请报 9800005）；
 *  - 收到系统取消/挂起事件 → 5s 内重申请（T3 实测结论「取消即重申请」，见 docs/T3-内核保活.md）。
 *
 * API 26 实测事实（SDK d.ts 核对）：
 *  - startBackgroundRunning(context, DATA_TRANSFER, wantAgent) 成功后由系统自动挂「常驻通知」（无提示音），
 *    无需自行 publishNotification；
 *  - DATA_TRANSFER 有系统侧约束：进度/速度长期不更新（>10min）或低速会被系统取消，
 *    取消原因见 ContinuousTaskCancelReason：SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED=4 /
 *    SYSTEM_CANCEL_DATA_TRANSFER_NOT_UPDATE=12 —— VPN 低流量空闲时可能命中，必须靠事件监听暴露；
 *  - on('continuousTaskCancel' | 'continuousTaskSuspend')（API 15/20 起）是系统回收的一手信号；
 *  - getAllContinuousTasks(context, includeSuspended) 可随时盘长时任务状态（回收检测）。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'KeepAlive';

export class KeepAlive {
  private static taskId: number = -1;
  private static started: boolean = false;
  private static watching: boolean = false;
  /** 当前长时任务类型（默认 dataTransfer；开启静音音频保活时切为 audioPlayback） */
  private static modes: string[] = ['dataTransfer'];
  /** 最近一次 report() 盘到的长时任务数（0 = 已被系统取消，供主进程做回收判定） */
  static taskCount: number = 0;

  /** 切换长时任务类型（配合静音音频保活）；切换后需重新 start 才生效 */
  static setModes(modes: string[]): void {
    KeepAlive.modes = modes;
  }

  /** 当前是否已持有长时任务（供调用方避免重复申请 9800005） */
  static isStarted(): boolean {
    return KeepAlive.started;
  }

  /** 申请 dataTransfer 长时任务（成功即挂常驻通知）。返回可读结果串，供 UI 日志。 */
  static async start(context: common.UIAbilityContext): Promise<string> {
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'cn.luoqingciya.arkhon',
            abilityName: 'EntryAbility',
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      // 注：string[] 重载才返回 ContinuousTaskNotification（单枚举重载返回 void）
      const resp: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, KeepAlive.modes, agent);
      const taskId: number = resp.continuousTaskId ?? resp.notificationId;
      KeepAlive.taskId = taskId;
      KeepAlive.started = true;
      hilog.info(DOMAIN, TAG, '[KEEP] longtask start ok taskId=%{public}d notifId=%{public}d',
        taskId, resp.notificationId);
      return `长时任务已启动 taskId=${taskId}`;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP] longtask start failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      return `长时任务启动失败 code=${err.code} msg=${err.message}`;
    }
  }

  /** 停止长时任务（VPN 停止时调用，常驻通知一并撤下）。幂等：未申请/已停止时直接跳过。 */
  static async stop(context: common.UIAbilityContext): Promise<string> {
    if (!KeepAlive.started) {
      return '长时任务未启动（跳过停止）';
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      KeepAlive.taskId = -1;
      KeepAlive.started = false;
      hilog.info(DOMAIN, TAG, '[KEEP] longtask stopped');
      return '长时任务已停止';
    } catch (e) {
      const err = e as BusinessError;
      // 系统已把任务取消（如低速/未更新被判失效）时同样视作停止态，避免状态卡死
      KeepAlive.started = false;
      hilog.error(DOMAIN, TAG, '[KEEP] longtask stop failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      return `长时任务停止失败 code=${err.code} msg=${err.message}`;
    }
  }

  /** 定期刷新长时任务（DATA_TRANSFER 有「>10min 不更新进度即取消」约束，靠定期 update 对抗） */
  static async refresh(context: common.UIAbilityContext): Promise<string> {
    if (!KeepAlive.started) {
      return '长时任务未启动（跳过刷新）';
    }
    try {
      const resp: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(context, KeepAlive.modes);
      hilog.info(DOMAIN, TAG, '[KEEP] longtask refreshed notifId=%{public}d', resp.notificationId);
      return '长时任务已刷新';
    } catch (e) {
      const err = e as BusinessError;
      // 系统已取消时刷新会失败：置回未启动态，交给重申请逻辑处理
      KeepAlive.started = false;
      hilog.warn(DOMAIN, TAG, '[KEEP] longtask refresh failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      return `长时任务刷新失败 code=${err.code} msg=${err.message}`;
    }
  }

  /** 回收检测：盘点本 App 当前长时任务（数量/暂停态/宿主 pid），并刷新 KeepAlive.taskCount */
  static async report(context: common.UIAbilityContext): Promise<string> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(context);
      KeepAlive.taskCount = tasks.length;
      if (tasks.length === 0) {
        return '长时任务: 0 个（已被系统取消）';
      }
      let s = `长时任务: ${tasks.length} 个`;
      for (const t of tasks) {
        s += ` [id=${t.continuousTaskId} pid=${t.pid} suspend=${t.suspendState ? 'Y' : 'N'}]`;
      }
      return s;
    } catch (e) {
      const err = e as BusinessError;
      return `长时任务查询失败 code=${err.code} msg=${err.message}`;
    }
  }

  /** 注册系统取消/挂起监听（幂等）。事件上报给 UI 回调与 hilog。 */
  static watch(onEvent: (line: string) => void): void {
    if (KeepAlive.watching) {
      return;
    }
    KeepAlive.watching = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          // 系统取消后本地状态复位：允许后续重新申请，且 stop() 幂等跳过
          KeepAlive.started = false;
          KeepAlive.taskCount = 0;
          // detail（API 26）：细分原因，如 12=DATA_TRANSFER_NOT_UPDATE（>10min 未更新进度被回收）
          const detail: number = info.detailedReason ?? -1;
          const line = `[回收信号] 长时任务被取消 id=${info.id} reason=${info.reason} detail=${detail}`;
          hilog.error(DOMAIN, TAG, '%{public}s', line);
          onEvent(line);
        });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
          const line = `[回收信号] 长时任务挂起 id=${info.continuousTaskId}`
            + ` state=${info.suspendState ? 'Y' : 'N'} reason=${info.suspendReason}`;
          hilog.warn(DOMAIN, TAG, '%{public}s', line);
          onEvent(line);
        });
      // API 20：长时任务恢复激活事件（被系统恢复时的正向信号）
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo) => {
          const line = `[回收信号] 长时任务重新激活 id=${info.id}`;
          hilog.info(DOMAIN, TAG, '%{public}s', line);
          onEvent(line);
        });
      hilog.info(DOMAIN, TAG, '[KEEP] continuous-task watchers registered');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP] watch 注册失败 code=%{public}d msg=%{public}s',
        err.code, err.message);
    }
  }
}