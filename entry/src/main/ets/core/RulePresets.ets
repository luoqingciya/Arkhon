/**
 * M3 · B2 分流预设：内置离线域名规则集（全部 opt-in，默认关闭）
 *
 * 约束与设计：
 *  - 仅静态 DOMAIN-SUFFIX 表，不依赖 geoip/geosite 数据文件（离线可用、无加载失败风险）；
 *  - 展开顺序固定为「广告拦截 → 国内直连 → 流媒体代理 → AI 代理」（见 RULE_PRESETS 声明序），
 *    与 ConfigBuilder 的私网直连前缀、MATCH 兜底共同组成最终规则表；
 *  - 勾选状态由 ProfileStore 持久化（store.json settings.rulePresets）。
 */

export interface RulePreset {
  id: string;
  label: string;
  desc: string;
  /** 命中后的出口策略：DIRECT / REJECT / PROXY */
  policy: string;
  domains: string[];
}

/** 广告与跟踪（REJECT 优先于其它预设：即使用户开了国内直连，广告域名也先被拦掉） */
const AD_DOMAINS: string[] = [
  'doubleclick.net',
  'googleadservices.com',
  'googlesyndication.com',
  'google-analytics.com',
  'googletagmanager.com',
  'googletagservices.com',
  'adservice.google.com',
  'admob.com',
  'umeng.com',
  'umengcloud.com',
  'cnzz.com',
  'alimama.com',
  'mmstat.com',
  'miaozhen.com',
  'admaster.com.cn',
  'tanx.com',
  'gdt.qq.com',
  'e.qq.com',
  'ad.qq.com',
  'union.baidu.com',
  'pangolin-sdk-toutiao.com',
  'simba.taobao.com',
  'adjust.com',
  'appsflyer.com',
  'adsafeprotected.com',
  'scorecardresearch.com',
  'moatads.com',
  'adcolony.com',
  'applovin.com',
  'unityads.unity3d.com',
  'vungle.com',
  'chartboost.com',
  'tapjoy.com',
  'inmobi.com',
  'mintegral.com'
];

/** 国内直连（含 .cn 全后缀；B 站等国内平台置于此，如需代理请用节点页手动切换） */
const CN_DOMAINS: string[] = [
  'baidu.com',
  'baidubce.com',
  'bdstatic.com',
  'qq.com',
  'tencent.com',
  'tencent-cloud.com',
  'myqcloud.com',
  'qcloud.com',
  'weixin.com',
  'wechat.com',
  'alipay.com',
  'alibaba.com',
  'alicdn.com',
  'aliyun.com',
  'aliyuncs.com',
  'taobao.com',
  'tmall.com',
  'jd.com',
  '360buyimg.com',
  'pinduoduo.com',
  'yangkeduo.com',
  'meituan.com',
  'dianping.com',
  'ele.me',
  'sina.com.cn',
  'weibo.com',
  'sinaimg.cn',
  'weibocdn.com',
  'sohu.com',
  '163.com',
  '126.net',
  '127.net',
  'bilibili.com',
  'hdslb.com',
  'douyin.com',
  'bytedance.com',
  'byteimg.com',
  'toutiao.com',
  'ixigua.com',
  'zhihu.com',
  'zhimg.com',
  'juejin.cn',
  'csdn.net',
  'gitee.com',
  'oschina.net',
  'cnblogs.com',
  'ctrip.com',
  'qunar.com',
  '12306.cn',
  'amap.com',
  'autonavi.com',
  'didiglobal.com',
  'xiaojukeji.com',
  'xiaomi.com',
  'mi.com',
  'miui.com',
  'huawei.com',
  'hicloud.com',
  'honor.com',
  'oppo.com',
  'vivo.com',
  'oneplus.com',
  'lenovo.com.cn',
  'netease.com',
  '17173.com',
  '58.com',
  'kingsoft.com',
  'wps.cn',
  'wps.com',
  'kdocs.cn',
  'iflytek.com',
  'xunlei.com',
  'iqiyi.com',
  'qiyi.com',
  'youku.com',
  'mgtv.com',
  'kugou.com',
  'kuwo.cn',
  'cn'
];

/** 流媒体（走代理） */
const STREAM_DOMAINS: string[] = [
  'youtube.com',
  'youtubekids.com',
  'googlevideo.com',
  'ytimg.com',
  'ggpht.com',
  'netflix.com',
  'nflxvideo.net',
  'nflxso.net',
  'nflximg.net',
  'hulu.com',
  'disneyplus.com',
  'disney-plus.net',
  'dssott.com',
  'bamgrid.com',
  'hbomax.com',
  'hbomaxcdn.com',
  'primevideo.com',
  'amazonvideo.com',
  'aiv-cdn.net',
  'spotify.com',
  'scdn.co',
  'twitch.tv',
  'ttvnw.net',
  'jtvnw.net',
  'soundcloud.com',
  'pandora.com',
  'iheart.com',
  'vimeo.com',
  'vimeocdn.com',
  'dailymotion.com',
  'dmcdn.net',
  'crunchyroll.com',
  'vrv.co',
  'funimation.com',
  'abema.tv',
  'abematv.akamaized.net',
  'nicovideo.jp',
  'nimg.jp',
  'bahamut.com.tw',
  'gamer.com.tw',
  'tving.com',
  'wavve.com'
];

/** AI 服务（走代理） */
const AI_DOMAINS: string[] = [
  'openai.com',
  'chatgpt.com',
  'oaiusercontent.com',
  'openai.azure.com',
  'anthropic.com',
  'claude.ai',
  'gemini.google.com',
  'ai.google.dev',
  'makersuite.google.com',
  'aistudio.google.com',
  'generativelanguage.googleapis.com',
  'aiplatform.googleapis.com',
  'copilot.microsoft.com',
  'sydney.bing.com',
  'perplexity.ai',
  'poe.com',
  'midjourney.com',
  'civitai.com',
  'huggingface.co',
  'hf.co',
  'groq.com',
  'x.ai',
  'mistral.ai',
  'cohere.ai',
  'stability.ai',
  'elevenlabs.io',
  'suno.com',
  'runwayml.com',
  'lumalabs.ai',
  'krea.ai',
  'character.ai',
  'together.ai',
  'openrouter.ai',
  'replicate.com'
];

/** 预设清单（声明顺序即规则展开顺序：ad → direct-cn → stream → ai） */
export const RULE_PRESETS: RulePreset[] = [
  {
    id: 'ad',
    label: '广告与跟踪拦截',
    desc: '常见广告/统计/追踪域名',
    policy: 'REJECT',
    domains: AD_DOMAINS
  },
  {
    id: 'direct-cn',
    label: '国内直连',
    desc: '国内站点与 .cn 域名直连，减少代理绕行',
    policy: 'DIRECT',
    domains: CN_DOMAINS
  },
  {
    id: 'stream',
    label: '流媒体代理',
    desc: 'YouTube / Netflix / Spotify 等',
    policy: 'PROXY',
    domains: STREAM_DOMAINS
  },
  {
    id: 'ai',
    label: 'AI 服务代理',
    desc: 'OpenAI / Claude / Gemini 等',
    policy: 'PROXY',
    domains: AI_DOMAINS
  }
];

export function presetById(id: string): RulePreset | null {
  for (const p of RULE_PRESETS) {
    if (p.id === id) {
      return p;
    }
  }
  return null;
}

/** 勾选集合展开为 mihomo 规则行（未勾选返回空数组；顺序保证 ad 优先级最高） */
export function presetRuleLines(presetIds: string[]): string[] {
  const lines: string[] = [];
  for (const p of RULE_PRESETS) {
    if (presetIds.indexOf(p.id) < 0) {
      continue;
    }
    for (const d of p.domains) {
      lines.push(`DOMAIN-SUFFIX,${d},${p.policy}`);
    }
  }
  return lines;
}