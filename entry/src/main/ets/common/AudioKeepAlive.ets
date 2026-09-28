/**
 * T3 保活增强：静音音频保活（对标 ClashBox「内核前台模式 + 模拟后台」）
 *
 * ⚠️ 实测结论（2026-09-28 · Mate 80 Pro · API 26）——**本方案已被系统主动反制，默认关闭、仅保留实现供后续系统版本复测**：
 *   息屏后约 30 秒主进程被冻结，系统日志给出完整证据链：
 *     `[WriteMuteDataSysEvent] write silent data for some time`（渲染器静音数据检测）
 *     → `[TASK_DETECTION] all sessions are mute: 1`
 *     → `[SUSPEND_MSG] enter silent, is all session mute : 1`
 *     → `[SUSPEND_MANAGER] Doze ... / Freeze pid: xxx success`（长时任务豁免在此路径下不生效）
 *   即：静音音频保活在本代系统上不成立；回归复测方法见 `docs/T3-内核保活.md` 实验 5。
 *
 * 原理备忘：`AUDIO_PLAYBACK` 长时任务 + **真实运行的音频流** + **已连接的 AVSession**
 * （系统校验点：SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION=5 / ..._NOT_RUNNING=6）。
 *
 * 代价（若未来启用，须在设置项中向用户说明）：播控卡片/媒体通知常驻、电量小幅增加、审核需说明用途。
 */
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeepAlive } from './KeepAlive';

const DOMAIN = 0x0000;
const TAG = 'AudioKeepAlive';
const SILENT_BUF_SIZE = 48000 * 2 * 2;   // 1s 静音：48kHz / 双声道 / S16LE
const UPDATE_MS = 5000;                  // AVSession 播放位置心跳
const LOG_EVERY_WRITES = 30;             // 静音写循环的节奏日志（防"空转"误判）

export class AudioKeepAlive {
  private static renderer: audio.AudioRenderer | null = null;
  private static session: avSession.AVSession | null = null;
  private static writing: boolean = false;
  private static started: boolean = false;
  private static posTimer: number = -1;
  private static writeCount: number = 0;

  static isOn(): boolean {
    return AudioKeepAlive.started;
  }

  /** 启动静音音频保活：AVSession → 静音流 → 播放态 → AUDIO_PLAYBACK 长时任务 */
  static async start(context: common.UIAbilityContext): Promise<string> {
    if (AudioKeepAlive.started) {
      return '静音音频保活已在运行';
    }
    try {
      // 1) AVSession（系统校验：AUDIO_PLAYBACK 必须连接 AVSession）
      const session: avSession.AVSession =
        await avSession.createAVSession(context, 'arkhon-keepalive', 'audio');
      const meta: avSession.AVMetadata = {
        assetId: 'arkhon-keepalive',
        title: 'Arkhon 隧道保活',
        artist: 'Arkhon',
      };
      await session.setAVMetadata(meta);
      await session.activate();
      AudioKeepAlive.session = session;

      // 2) 静音音频流（系统校验：必须真的在播）
      const options: audio.AudioRendererOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_2,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        },
        rendererInfo: {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0,
        },
      };
      const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
      AudioKeepAlive.renderer = renderer;
      renderer.on('audioInterrupt', (ev: audio.InterruptEvent) => {
        // 被其他应用打断时仅记录：写循环若因此中断，由上层重启（PoC 范围）
        hilog.warn(DOMAIN, TAG, '[KEEP-A] audioInterrupt type=%{public}d hint=%{public}d',
          ev.eventType, ev.hintType);
      });
      await renderer.start();

      // 3) 播控状态置为 PLAY
      const st: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        speed: 1,
      };
      await session.setAVPlaybackState(st);
      AudioKeepAlive.startPosHeartbeat(session);

      // 4) 写静音流（保持音频流处于 RUNNING 状态）
      AudioKeepAlive.writing = true;
      AudioKeepAlive.writeCount = 0;
      AudioKeepAlive.writeLoop(renderer);

      // 5) 长时任务切到 AUDIO_PLAYBACK（替换 dataTransfer，避免同 Ability 双任务）
      KeepAlive.setModes(['audioPlayback']);
      await KeepAlive.stop(context);
      const taskMsg: string = await KeepAlive.start(context);

      AudioKeepAlive.started = true;
      hilog.info(DOMAIN, TAG, '[KEEP-A] silent-audio keepalive started');
      return `静音音频保活已启动（${taskMsg}）`;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP-A] start failed code=%{public}d msg=%{public}s', err.code, err.message);
      await AudioKeepAlive.stop(context);
      return `静音音频保活启动失败 code=${err.code} msg=${err.message}`;
    }
  }

  /** 停止静音音频保活：长时任务切回 dataTransfer，释放音频流与会话 */
  static async stop(context: common.UIAbilityContext): Promise<string> {
    AudioKeepAlive.writing = false;
    if (AudioKeepAlive.posTimer >= 0) {
      clearInterval(AudioKeepAlive.posTimer);
      AudioKeepAlive.posTimer = -1;
    }
    try {
      if (AudioKeepAlive.renderer !== null) {
        await AudioKeepAlive.renderer.stop();
        await AudioKeepAlive.renderer.release();
        AudioKeepAlive.renderer = null;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '[KEEP-A] renderer release 失败 msg=%{public}s', (e as BusinessError).message);
    }
    try {
      if (AudioKeepAlive.session !== null) {
        await AudioKeepAlive.session.deactivate();
        await AudioKeepAlive.session.destroy();
        AudioKeepAlive.session = null;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '[KEEP-A] session destroy 失败 msg=%{public}s', (e as BusinessError).message);
    }
    if (AudioKeepAlive.started) {
      AudioKeepAlive.started = false;
      KeepAlive.setModes(['dataTransfer']);
      await KeepAlive.stop(context);
      const taskMsg: string = await KeepAlive.start(context);
      return `静音音频保活已停止（${taskMsg}）`;
    }
    return '静音音频保活已停止';
  }

  /** 静音写循环：持续喂 1s 静音缓冲，保持音频流 RUNNING（系统按"是否真在播"校验） */
  private static async writeLoop(renderer: audio.AudioRenderer): Promise<void> {
    const silent: ArrayBuffer = new ArrayBuffer(SILENT_BUF_SIZE);   // 全 0 = 静音
    while (AudioKeepAlive.writing) {
      try {
        await renderer.write(silent);
        AudioKeepAlive.writeCount++;
        if (AudioKeepAlive.writeCount % LOG_EVERY_WRITES === 0) {
          // 节奏自检：正常应约 1 次/秒；若 30 次远快于 30 秒即为异常"空转"
          hilog.info(DOMAIN, TAG, '[KEEP-A] silent writes=%{public}d', AudioKeepAlive.writeCount);
        }
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '[KEEP-A] write 中断 code=%{public}d msg=%{public}s', err.code, err.message);
        break;
      }
    }
  }

  /** AVSession 播放位置心跳：让播控卡片状态保持"正在播放" */
  private static startPosHeartbeat(session: avSession.AVSession): void {
    if (AudioKeepAlive.posTimer >= 0) {
      clearInterval(AudioKeepAlive.posTimer);
    }
    let pos = 0;
    AudioKeepAlive.posTimer = setInterval(() => {
      pos += UPDATE_MS;
      const st: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        speed: 1,
        position: { elapsedTime: pos, updateTime: Date.now() },
      };
      session.setAVPlaybackState(st).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '[KEEP-A] setAVPlaybackState 失败 code=%{public}d', err.code);
      });
    }, UPDATE_MS);
  }
}