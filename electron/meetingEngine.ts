/**
 * 会议助手引擎（组会模式 & 翻译总结模式共用）
 *
 * 音频分段 → 逐段 Whisper 转写（带术语提示）→ 实时转写流
 *   → 按触发方式（全部问题 / 点名 / 手动热键）判断是否需要弹卡
 *   → 用「画像 + 文档 + 场景 + 本周进展 + 历史记忆 + 实时转写」流式生成会议答题卡
 * 另外负责：会前准备、画像草稿、中文→英文快捷口语、会后记忆提炼。
 */
import OpenAI from 'openai';
import { transcribeSegmentVerbose, transcribeLongPcm } from './asrService';
import { getSettings, getApiKey } from './settingsStore';
import { getOpenAICompatibleBaseUrl, openaiChatModelOptions } from './providerConfig';
import { getContextFiles } from './contextStore';
import {
  isNoiseOrUnrecognizedQuestionZh,
  type MeetingCardChunk,
  type MeetingCardData,
  type MeetingPrep,
  type MeetingSession,
  type MeetingTranscriptLine,
  type Settings
} from './types';
import {
  appendSessionCard,
  appendSessionTranscript,
  endActiveSession,
  ensureActiveSession,
  getActiveSession,
  getMeetingProfileState,
  getUndigestedEndedSessions,
  setMeetingPrep,
  setSessionDigest
} from './meetingProfile';
import {
  SCENE_LABEL_ZH,
  buildMeetingSystemPrompt,
  buildMeetingUserPrompt,
  buildPastMeetingsBlock,
  buildPersonaBlock,
  buildProjectDocsBlock,
  type MeetingTriggerKind
} from './meetingPrompt';
import {
  MEETING_MEMORY_DIGEST_PROMPT,
  MEETING_PERSONA_DRAFT_PROMPT,
  buildMeetingPrepPrompt,
  buildMeetingQuickEnPrompt
} from './sharedPrompts';

export interface MeetingEngineDeps {
  send: (channel: string, payload: unknown) => void;
  /** 把当前正在录、尚未静音切段的音频立即切出来（手动「回答刚才的问题」时用） */
  flushActiveAudio: () => void;
}

/** 内存中保留的实时转写时长 */
const TRANSCRIPT_KEEP_MS = 30 * 60 * 1000;
/** 答题时注入的实时转写窗口 */
const PROMPT_TRANSCRIPT_MS = 4 * 60 * 1000;
const PROMPT_TRANSCRIPT_MAX_CHARS = 6000;
/** 小于该时长的语音段大概率是噪声 / 单字，不转写 */
const MIN_SEGMENT_SEC = 0.6;
const LONG_SEGMENT_SEC = 25;

/** Whisper 在静音 / 噪声上常见的幻觉输出 */
const HALLUCINATION_RE =
  /^(thank you( (so much|very much))?[.!]*|thanks( for watching)?[.!]*|thank you for watching[.!]*|you[.!]*|bye[.!]*|subtitles? by.*|transcribed by.*|字幕.*|请不吝点赞.*|謝謝觀看.*|谢谢观看.*|[.。…\s]*)$/i;

const STRONG_CUE_RE =
  /\b(over to you|your turn|what do you think|what's your (view|take|opinion|thought)|what is your (view|take|opinion)|your thoughts|any thoughts on|how about you|from your side|on your side|can you (explain|share|walk us|tell us|clarify|elaborate|give us|update us)|could you (explain|share|walk us|tell us|clarify|elaborate|give us|update us)|would you (explain|share|walk us|tell us|clarify|elaborate))\b/i;

const QUESTION_LIKE_EN_RE =
  /\?|^\s*(what|where|when|why|how|who|which|can|could|would|will|do|does|did|is|are|have|has|should|shall)\b|\b(can|could|would|will|do|did) you\b|\b(tell|explain|walk|share|clarify|elaborate)\b/i;
const QUESTION_LIKE_ZH_RE = /[吗呢？?]|为什么|怎么|如何|什么|哪些|能不能|可不可以|是不是|有没有/;

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function wordCount(text: string): number {
  const cjk = (text.match(/[一-鿿]/g) ?? []).length;
  const words = text.replace(/[一-鿿]/g, ' ').split(/\s+/).filter(Boolean).length;
  return words + Math.ceil(cjk / 2);
}

// ─────────────────────────────────────────────
// LLM 客户端（所有服务商都走 OpenAI 兼容接口）
// ─────────────────────────────────────────────

async function getChatClient(settings: Settings): Promise<{ client: OpenAI; model: string }> {
  const provider = settings.apiProvider ?? 'openai';
  if (provider === 'ollama') {
    const base = (settings.ollamaBaseUrl?.trim() || 'http://localhost:11434').replace(/\/+$/, '');
    return { client: new OpenAI({ apiKey: 'ollama', baseURL: `${base}/v1` }), model: settings.model };
  }
  const apiKey = await getApiKey(provider);
  if (!apiKey) throw new Error('未配置 API Key');
  if (provider === 'google') {
    return {
      client: new OpenAI({ apiKey, baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai/' }),
      model: settings.model
    };
  }
  const baseURL = getOpenAICompatibleBaseUrl(provider);
  return { client: new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) }), model: settings.model };
}

async function completeJson<T>(system: string, user: string, maxTokens: number): Promise<T> {
  const settings = getSettings();
  const { client, model } = await getChatClient(settings);
  const res = await client.chat.completions.create({
    ...openaiChatModelOptions(model, { temperature: 0.3, maxTokens, json: true }),
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user }
    ]
  } as any);
  const text = (res as any).choices?.[0]?.message?.content ?? '';
  return parseJsonLoose<T>(text);
}

function parseJsonLoose<T>(text: string): T {
  const trimmed = text.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
  try {
    return JSON.parse(trimmed) as T;
  } catch {
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start >= 0 && end > start) return JSON.parse(trimmed.slice(start, end + 1)) as T;
    throw new Error('模型未返回有效 JSON');
  }
}

// ─────────────────────────────────────────────
// 流式 JSON：边生成边提取字段（允许最后一个字符串未闭合）
// ─────────────────────────────────────────────

function unescapeJsonString(raw: string): string {
  // 去掉末尾不完整的转义
  let s = raw.replace(/\\u[0-9a-fA-F]{0,3}$/, '').replace(/\\$/, '');
  try {
    return JSON.parse(`"${s}"`);
  } catch {
    return s.replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
}

const CARD_STRING_FIELDS = [
  'question_zh',
  'q_type',
  'opener_en',
  'concise_answer_en',
  'expanded_answer_en',
  'source',
  'caution_zh'
] as const;

export function parsePartialMeetingCard(acc: string): MeetingCardData {
  const out: MeetingCardData = {};
  for (const field of CARD_STRING_FIELDS) {
    const m = acc.match(new RegExp(`"${field}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)`));
    if (m) (out as any)[field] = unescapeJsonString(m[1]);
  }
  const arr = acc.match(/"points_en"\s*:\s*\[([\s\S]*?)(\]|$)/);
  if (arr) {
    const items: string[] = [];
    const re = /"((?:[^"\\]|\\.)*)("?)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(arr[1])) !== null) {
      const v = unescapeJsonString(m[1]);
      if (v.trim()) items.push(v);
    }
    out.points_en = items;
  }
  return out;
}

// ─────────────────────────────────────────────
// 引擎
// ─────────────────────────────────────────────

interface PendingCardJob {
  trigger: MeetingTriggerKind;
  utterance: string;
  imageBase64?: string;
}

export class MeetingEngine {
  private deps: MeetingEngineDeps;
  private lines: MeetingTranscriptLine[] = [];
  private nextLineId = 1;
  private lineListeners: ((line: MeetingTranscriptLine) => void)[] = [];

  // ASR：并发转写、按顺序提交
  private asrSeq = 0;
  private asrCommitSeq = 0;
  private asrResults = new Map<number, { text: string; at: number } | null>();
  private asrInflight = new Set<Promise<void>>();

  // 触发
  private triggerTimer: ReturnType<typeof setTimeout> | null = null;
  private triggerKind: MeetingTriggerKind | null = null;
  private triggerFromLineId = 0;
  private triggerArmedAt = 0;

  // 卡片生成（串行；排队时只保留最新一个）
  private cardBusy = false;
  private pendingJob: PendingCardJob | null = null;
  private nextCardId = 1;

  private digestRunning = false;
  private glossaryCache: { source: string; terms: string } | null = null;
  private sessionId: string | null = null;

  constructor(deps: MeetingEngineDeps) {
    this.deps = deps;
  }

  onLine(listener: (line: MeetingTranscriptLine) => void): () => void {
    this.lineListeners.push(listener);
    return () => {
      this.lineListeners = this.lineListeners.filter(l => l !== listener);
    };
  }

  getTranscript(): MeetingTranscriptLine[] {
    return this.lines.slice();
  }

  /** 开始监听（组会 / 翻译模式）时调用：进入（或续上）本场会议 */
  beginSession() {
    const settings = getSettings();
    const session = ensureActiveSession(settings.meetingScene ?? 'weekly');
    if (session.id !== this.sessionId) {
      this.sessionId = session.id;
      this.lines = session.transcript.slice(-80).map(t => ({ id: this.nextLineId++, text: t.text, at: t.at }));
      this.deps.send('meeting:transcriptReset', this.lines);
    }
    this.digestPendingSessions().catch(err => console.error('[Meeting] 记忆提炼失败', err));
  }

  /** 结束本场会议：清空实时转写并在后台提炼记忆 */
  async endSession(): Promise<{ ok: boolean }> {
    this.clearTrigger();
    await this.waitForAsr(3000);
    const ended = endActiveSession();
    this.sessionId = null;
    this.lines = [];
    this.deps.send('meeting:transcriptReset', []);
    if (ended) {
      this.digestPendingSessions().catch(err => console.error('[Meeting] 记忆提炼失败', err));
    }
    return { ok: true };
  }

  // ── ASR ───────────────────────────────────────

  ingestAudio(segment: Buffer, sampleRate: number) {
    const durationSec = segment.length / (sampleRate * 2);
    if (durationSec < MIN_SEGMENT_SEC) return;
    const seq = this.asrSeq++;
    const at = Date.now();
    const p = this.transcribe(segment, sampleRate, durationSec)
      .then(text => {
        this.asrResults.set(seq, text ? { text, at } : null);
      })
      .catch(err => {
        console.error('[Meeting] 转写失败', err);
        this.asrResults.set(seq, null);
      })
      .finally(() => {
        this.asrInflight.delete(p);
        this.commitAsr();
      });
    this.asrInflight.add(p);
  }

  private async transcribe(segment: Buffer, sampleRate: number, durationSec: number): Promise<string> {
    const settings = getSettings();
    const openaiKey = await getApiKey('openai');
    if (!openaiKey && !settings.mockAsr) {
      console.warn('[Meeting] 无 OpenAI Key，无法转写');
      return '';
    }
    let text: string;
    if (durationSec > LONG_SEGMENT_SEC) {
      text = (await transcribeLongPcm([segment], openaiKey ?? '', settings.mockAsr, sampleRate)).text;
    } else {
      const r = await transcribeSegmentVerbose(segment, openaiKey ?? '', settings.mockAsr, sampleRate, this.whisperPrompt());
      text = r.text;
    }
    text = (text ?? '').trim();
    if (!text || HALLUCINATION_RE.test(text)) return '';
    return text;
  }

  private commitAsr() {
    while (this.asrResults.has(this.asrCommitSeq)) {
      const r = this.asrResults.get(this.asrCommitSeq);
      this.asrResults.delete(this.asrCommitSeq);
      this.asrCommitSeq++;
      if (r) this.addLine(r.text, r.at);
    }
  }

  /** 等正在进行的逐段转写完成（翻译总结前调用） */
  waitForPendingTranscription(timeoutMs: number): Promise<void> {
    return this.waitForAsr(timeoutMs);
  }

  private async waitForAsr(timeoutMs: number) {
    if (this.asrInflight.size === 0) return;
    await Promise.race([
      Promise.allSettled(Array.from(this.asrInflight)),
      new Promise(resolve => setTimeout(resolve, timeoutMs))
    ]);
  }

  /** Whisper 提示：画像 / 文档里的专有名词 + 最近一句转写，提升人名与术语识别率 */
  private whisperPrompt(): string {
    const persona = getMeetingProfileState().personaText;
    const keywords = getSettings().meetingTriggerKeywords ?? '';
    const source = `${persona}\n${keywords}`;
    if (!this.glossaryCache || this.glossaryCache.source !== source) {
      const counts = new Map<string, number>();
      const tokens = source.match(/\b([A-Z][a-zA-Z0-9]+(?:[-\s][A-Z0-9][a-zA-Z0-9]+)?|[A-Z]{2,}[0-9]*|[A-Za-z]+[0-9]+[A-Za-z0-9]*)\b/g) ?? [];
      for (const t of tokens) {
        if (t.length < 3) continue;
        counts.set(t, (counts.get(t) ?? 0) + 1);
      }
      const kw = keywords.split(/[,，;；\n]/).map(s => s.trim()).filter(Boolean);
      const terms = [...kw, ...Array.from(counts.entries()).sort((a, b) => b[1] - a[1]).map(([t]) => t)]
        .filter((t, i, arr) => arr.indexOf(t) === i)
        .slice(0, 40)
        .join(', ');
      this.glossaryCache = { source, terms };
    }
    const tail = this.lines.length ? this.lines[this.lines.length - 1].text.slice(-160) : '';
    const prompt = [this.glossaryCache.terms ? `Terms: ${this.glossaryCache.terms}.` : '', tail].filter(Boolean).join(' ');
    return prompt.slice(0, 700);
  }

  private addLine(text: string, at: number) {
    const line: MeetingTranscriptLine = { id: this.nextLineId++, text, at };
    this.lines.push(line);
    const cutoff = Date.now() - TRANSCRIPT_KEEP_MS;
    if (this.lines.length > 400 || (this.lines[0] && this.lines[0].at < cutoff)) {
      this.lines = this.lines.filter(l => l.at >= cutoff).slice(-400);
    }
    appendSessionTranscript(text, at);
    this.deps.send('meeting:transcript', line);
    for (const l of this.lineListeners) {
      try {
        l(line);
      } catch (e) {
        console.error(e);
      }
    }
    this.evaluateTrigger(line);
  }

  // ── 触发 ──────────────────────────────────────

  private mentionKeywords(): RegExp[] {
    const raw = getSettings().meetingTriggerKeywords ?? '';
    return raw
      .split(/[,，;；\n]/)
      .map(s => s.trim())
      .filter(s => s.length >= 2)
      .map(k => (/^[\x00-\x7f]+$/.test(k) ? new RegExp(`\\b${escapeRegExp(k)}\\b`, 'i') : new RegExp(escapeRegExp(k), 'i')));
  }

  private evaluateTrigger(line: MeetingTranscriptLine) {
    const settings = getSettings();
    const mode = settings.meetingTrigger ?? 'mention';
    const scene = settings.meetingScene ?? 'weekly';
    if (mode === 'manual') return;

    // 已在等待（说话人可能还没说完问题）：新一段到来则顺延
    if (this.triggerTimer) {
      this.armTrigger(this.triggerKind ?? 'auto', this.triggerFromLineId);
      return;
    }

    const text = line.text;
    if (scene === 'interviewer') {
      // 面试官场景：候选人说完一段较完整的回答后给追问建议
      if (mode === 'all' && wordCount(text) >= 12) this.armTrigger('auto', line.id);
      return;
    }

    if (mode === 'all') {
      if (wordCount(text) >= 4 && (QUESTION_LIKE_EN_RE.test(text) || QUESTION_LIKE_ZH_RE.test(text) || STRONG_CUE_RE.test(text))) {
        this.armTrigger('auto', line.id);
      }
      return;
    }

    // mention
    const hit = this.mentionKeywords().some(re => re.test(text)) || STRONG_CUE_RE.test(text);
    if (hit) this.armTrigger('mention', line.id);
  }

  private armTrigger(kind: MeetingTriggerKind, fromLineId: number) {
    const now = Date.now();
    if (!this.triggerTimer) {
      this.triggerKind = kind;
      this.triggerFromLineId = fromLineId;
      this.triggerArmedAt = now;
    }
    if (this.triggerTimer) clearTimeout(this.triggerTimer);
    // 等对方把问题说完：每来一段新转写顺延，最长等 8 秒
    const settle = kind === 'mention' ? 2200 : 1600;
    const remaining = Math.max(0, 8000 - (now - this.triggerArmedAt));
    this.triggerTimer = setTimeout(() => this.fireTrigger(), Math.min(settle, remaining));
  }

  private clearTrigger() {
    if (this.triggerTimer) clearTimeout(this.triggerTimer);
    this.triggerTimer = null;
    this.triggerKind = null;
  }

  private fireTrigger() {
    const kind = this.triggerKind ?? 'auto';
    const fromId = this.triggerFromLineId;
    this.clearTrigger();
    // 带上触发句之前一句（问题常被切成两段）
    const idx = this.lines.findIndex(l => l.id === fromId);
    const start = Math.max(0, idx - 1);
    const utterance = this.lines.slice(start).map(l => l.text).join(' ');
    this.enqueueCard({ trigger: kind, utterance });
  }

  /** 热键 / 按钮：「回答刚才这个问题」 */
  async answerNow(): Promise<{ ok: boolean; error?: string }> {
    this.clearTrigger();
    this.deps.flushActiveAudio();
    // 刚切出的段需要一点时间进入转写队列
    await new Promise(r => setTimeout(r, 50));
    await this.waitForAsr(5000);
    if (this.lines.length === 0) {
      return { ok: false, error: '还没有听到任何发言，请先开始监听' };
    }
    const now = Date.now();
    let recent = this.lines.filter(l => now - l.at <= 45_000);
    if (recent.length === 0) recent = this.lines.slice(-3);
    this.enqueueCard({ trigger: 'manual', utterance: recent.map(l => l.text).join(' ') });
    return { ok: true };
  }

  /** 截图答题（组会 / 翻译模式下复用会议答题卡） */
  answerFromImage(imageBase64: string): { ok: boolean } {
    this.enqueueCard({ trigger: 'screenshot', utterance: '', imageBase64 });
    return { ok: true };
  }

  // ── 答题卡生成 ─────────────────────────────────

  private enqueueCard(job: PendingCardJob) {
    if (this.cardBusy) {
      this.pendingJob = job;
      return;
    }
    this.cardBusy = true;
    (async () => {
      let current: PendingCardJob | null = job;
      while (current) {
        await this.generateCard(current).catch(err => console.error('[Meeting] 生成答题卡失败', err));
        current = this.pendingJob;
        this.pendingJob = null;
      }
    })().finally(() => {
      this.cardBusy = false;
    });
  }

  private promptTranscript(): { text: string; at: number }[] {
    const now = Date.now();
    const recent = this.lines.filter(l => now - l.at <= PROMPT_TRANSCRIPT_MS);
    const out: { text: string; at: number }[] = [];
    let total = 0;
    for (let i = recent.length - 1; i >= 0; i--) {
      total += recent[i].text.length;
      if (total > PROMPT_TRANSCRIPT_MAX_CHARS) break;
      out.unshift({ text: recent[i].text, at: recent[i].at });
    }
    return out;
  }

  private async generateCard(job: PendingCardJob) {
    const id = this.nextCardId++;
    const send = (chunk: Omit<MeetingCardChunk, 'id' | 'trigger'>) =>
      this.deps.send('meeting:cardChunk', { id, trigger: job.trigger, ...chunk } satisfies MeetingCardChunk);

    const settings = getSettings();
    if (settings.mockLlm) {
      send({
        partial: {
          question_zh: '（Mock）对方问：这周 CVS 评估有什么进展？',
          q_type: 'progress',
          opener_en: 'Sure — quick update on CVS.',
          points_en: ['C1–C3 scoring runs end to end', 'Not clinically validated yet', 'Next: annotation protocol'],
          concise_answer_en: 'The scoring pipeline runs end to end now, but it is not clinically validated yet.',
          expanded_answer_en: '',
          source: 'mock',
          caution_zh: ''
        },
        done: true
      });
      appendSessionCard({ question_zh: '（Mock）CVS 进展', answer: 'The scoring pipeline runs end to end now.', at: Date.now() });
      return;
    }

    const system = buildMeetingSystemPrompt(settings);
    const userText = buildMeetingUserPrompt({
      trigger: job.trigger,
      transcript: this.promptTranscript(),
      utterance: job.utterance
    });

    let acc = '';
    let shown = false;
    let skipped = false;
    let last = '';
    try {
      const { client, model } = await getChatClient(settings);
      const userContent: any = job.imageBase64
        ? [
            { type: 'text', text: userText },
            { type: 'image_url', image_url: { url: `data:image/png;base64,${job.imageBase64}` } }
          ]
        : userText;
      const stream = (await client.chat.completions.create({
        ...openaiChatModelOptions(model, { temperature: 0.3, maxTokens: 1400, json: true }),
        stream: true,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: userContent }
        ]
      } as any)) as unknown as AsyncIterable<any>;

      for await (const chunk of stream) {
        const delta = chunk.choices?.[0]?.delta?.content ?? '';
        if (!delta) continue;
        acc += delta;
        const partial = parsePartialMeetingCard(acc);
        if (!shown) {
          // question_zh 字段完整出现后再决定是否弹卡
          if (!/"question_zh"\s*:\s*"(?:[^"\\]|\\.)*"/.test(acc)) continue;
          if (isNoiseOrUnrecognizedQuestionZh(partial.question_zh)) {
            skipped = true;
            break;
          }
          shown = true;
        }
        const key = JSON.stringify(partial);
        if (key !== last) {
          last = key;
          send({ partial, done: false });
        }
      }

      if (skipped) {
        console.log('[Meeting] 本轮与我无关，跳过：', job.utterance.slice(0, 80));
        send({ partial: {}, done: true, skipped: true });
        return;
      }

      let final: MeetingCardData;
      try {
        final = parseJsonLoose<MeetingCardData>(acc);
      } catch {
        final = parsePartialMeetingCard(acc);
      }
      if (!final.question_zh || isNoiseOrUnrecognizedQuestionZh(final.question_zh)) {
        send({ partial: {}, done: true, skipped: true });
        return;
      }
      if (!Array.isArray(final.points_en)) final.points_en = [];
      send({ partial: final, done: true });

      const answer = (final.concise_answer_en || final.opener_en || '').trim();
      if (answer) appendSessionCard({ question_zh: final.question_zh, answer, at: Date.now() });
    } catch (err) {
      const message = (err as Error)?.message ?? String(err);
      console.error('[Meeting] 答题卡生成失败', err);
      send({
        partial: shown ? parsePartialMeetingCard(acc) : { question_zh: job.utterance.slice(0, 60) || '回答生成失败' },
        done: true,
        error: message
      });
    }
  }

  // ── 中文 → 英文快捷口语 ──────────────────────────

  async quickTranslate(text: string): Promise<{ say: string; shorter: string }> {
    const input = text.trim();
    if (!input) return { say: '', shorter: '' };
    const settings = getSettings();
    const transcript = this.promptTranscript().slice(-12).map(l => l.text).join('\n') || '(none)';
    const system = `${buildMeetingQuickEnPrompt(settings.answerLanguage)}

[MY PROFILE]
${buildPersonaBlock(12_000)}`;
    const user = `[LIVE TRANSCRIPT — recent]\n${transcript}\n\n[MY THOUGHT]\n${input}`;
    const r = await completeJson<{ say?: string; shorter?: string }>(system, user, 500);
    return { say: (r.say ?? '').trim(), shorter: (r.shorter ?? '').trim() };
  }

  // ── 会前准备 ────────────────────────────────────

  async generatePrep(): Promise<MeetingPrep> {
    const settings = getSettings();
    const state = getMeetingProfileState();
    if (!state.weeklyNotes.trim()) throw new Error('请先填写「本周进展」');
    const scene = settings.meetingScene ?? 'weekly';
    const system = buildMeetingPrepPrompt(settings.answerLanguage);
    const user = `[MEETING TYPE] ${SCENE_LABEL_ZH[scene]}

[MY PROFILE]
${buildPersonaBlock()}

[PROJECT DOCUMENTS]
${buildProjectDocsBlock(60_000)}

[PAST MEETINGS]
${buildPastMeetingsBlock(3)}

[MY NOTES FOR THIS MEETING]
${state.weeklyNotes.trim()}`;
    const r = await completeJson<Partial<MeetingPrep>>(system, user, 3000);
    const prep: MeetingPrep = {
      update_script_en: String(r.update_script_en ?? '').trim(),
      likely_questions: Array.isArray(r.likely_questions)
        ? r.likely_questions
            .filter(q => q && (q as any).question_en)
            .map(q => ({
              asker: q.asker ? String(q.asker) : undefined,
              question_en: String(q.question_en ?? ''),
              question_zh: q.question_zh ? String(q.question_zh) : undefined,
              answer_en: String(q.answer_en ?? '')
            }))
        : [],
      decisions_needed_en: Array.isArray(r.decisions_needed_en) ? r.decisions_needed_en.map(String) : [],
      generatedAt: Date.now()
    };
    setMeetingPrep(prep);
    return prep;
  }

  // ── 画像草稿 ────────────────────────────────────

  async draftPersona(): Promise<string> {
    const settings = getSettings();
    const files = getContextFiles().filter(f => f.rawText && f.docType !== 'job_description');
    if (files.length === 0) throw new Error('资料库里还没有文档，请先上传项目文档 / 简历');
    const docs = files.map(f => `=== ${f.fileName} ===\n${(f.rawText ?? '').trim()}`).join('\n\n').slice(0, 100_000);
    const { client, model } = await getChatClient(settings);
    const res = await client.chat.completions.create({
      ...openaiChatModelOptions(model, { temperature: 0.2, maxTokens: 3000 }),
      messages: [
        { role: 'system', content: MEETING_PERSONA_DRAFT_PROMPT },
        { role: 'user', content: docs }
      ]
    } as any);
    return String((res as any).choices?.[0]?.message?.content ?? '').trim();
  }

  // ── 跨会议记忆 ──────────────────────────────────

  private async digestSession(session: MeetingSession) {
    const transcript = session.transcript.map(t => t.text).join('\n').slice(-30_000);
    const cards = session.cards.map(c => `Q: ${c.question_zh}\nMy answer: ${c.answer}`).join('\n\n');
    const user = `[MEETING TYPE] ${SCENE_LABEL_ZH[session.scene] ?? session.scene}
[DATE] ${new Date(session.startedAt).toISOString().slice(0, 16).replace('T', ' ')}

[MY PROFILE — for names and context]
${buildPersonaBlock(6000)}

[ANSWER CARDS I WAS SHOWN]
${cards || '(none)'}

[TRANSCRIPT — other participants]
${transcript || '(none)'}`;
    const r = await completeJson<{ digest_zh?: string; commitments?: string[] }>(MEETING_MEMORY_DIGEST_PROMPT, user, 1200);
    setSessionDigest(
      session.id,
      String(r.digest_zh ?? '').trim() || '（本场没有与我相关的内容）',
      Array.isArray(r.commitments) ? r.commitments.map(String).filter(Boolean) : []
    );
  }

  async digestPendingSessions() {
    if (this.digestRunning) return;
    this.digestRunning = true;
    try {
      for (const s of getUndigestedEndedSessions()) {
        try {
          await this.digestSession(s);
          this.deps.send('meeting:profileUpdated', null);
        } catch (err) {
          console.error('[Meeting] 提炼会议记忆失败', s.id, err);
          break; // 多半是 Key / 网络问题，下次再试
        }
      }
    } finally {
      this.digestRunning = false;
    }
  }

  /** 供 UI 显示：当前会话的基本信息 */
  getActiveSessionInfo(): { id: string; startedAt: number; cards: number } | null {
    const s = getActiveSession();
    return s ? { id: s.id, startedAt: s.startedAt, cards: s.cards.length } : null;
  }
}

