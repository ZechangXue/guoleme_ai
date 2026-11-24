/**
 * Claude（Anthropic 官方 SDK）适配层。
 *
 * 应用里所有对话类调用都写成 OpenAI Chat Completions 的形状（client.chat.completions.create）。
 * 选择 Claude 服务商时，createChatClient 返回一个同形状的对象，底层走 Anthropic Messages API；
 * 其它服务商仍原样返回 new OpenAI(...)，行为完全不变。
 *
 * 语音转写（Whisper / Realtime）和向量检索 Claude 没有对应能力，继续使用 OpenAI Key。
 */
import Anthropic from '@anthropic-ai/sdk';
import OpenAI from 'openai';

export const DEFAULT_CLAUDE_MODEL = 'claude-opus-5-5';

/** 支持服务端拒答兜底（fallbacks: "default"）的模型 */
const FALLBACK_MODELS = new Set([
  'claude-opus-5-5',
  'claude-opus-5',
  'claude-sonnet-5-5',
  'claude-fable-5-1',
  'claude-fable-5-2'
]);

/** Anthropic API Key 以 sk-ant- 开头；用于在共享的调用点上区分服务商 */
export function isAnthropicKey(apiKey: string | null | undefined): boolean {
  return /^sk-ant-/.test((apiKey ?? '').trim());
}

/** 对话类调用的统一入口：Claude Key → Claude 适配器；其它 → OpenAI SDK（原逻辑） */
export function createChatClient(apiKey: string, baseURL?: string): OpenAI {
  if (isAnthropicKey(apiKey)) return new ClaudeChatAdapter(apiKey) as unknown as OpenAI;
  return new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) });
}

// ─────────────────────────────────────────────
// OpenAI 消息 → Anthropic 消息
// ─────────────────────────────────────────────

type OpenAIPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string } };

type OpenAIMessage = {
  role: 'system' | 'user' | 'assistant' | 'developer';
  content: string | OpenAIPart[];
};

const JSON_ONLY_INSTRUCTION =
  'Output only the raw JSON object. Do not wrap it in markdown code fences and do not add any text before or after it.';

function partToBlock(part: OpenAIPart): Anthropic.Beta.BetaContentBlockParam | null {
  if (part.type === 'text') return part.text ? { type: 'text', text: part.text } : null;
  const m = /^data:(image\/(?:png|jpeg|gif|webp));base64,(.+)$/s.exec(part.image_url?.url ?? '');
  if (!m) return null;
  return {
    type: 'image',
    source: {
      type: 'base64',
      media_type: m[1] as 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp',
      data: m[2]
    }
  };
}

function convertMessages(messages: OpenAIMessage[]): {
  system: string;
  messages: Anthropic.Beta.BetaMessageParam[];
} {
  const systemParts: string[] = [];
  const out: Anthropic.Beta.BetaMessageParam[] = [];
  for (const msg of messages) {
    if (msg.role === 'system' || msg.role === 'developer') {
      const text = typeof msg.content === 'string'
        ? msg.content
        : msg.content.filter((p): p is { type: 'text'; text: string } => p.type === 'text').map(p => p.text).join('\n');
      if (text.trim()) systemParts.push(text);
      continue;
    }
    const content = typeof msg.content === 'string'
      ? msg.content
      : msg.content.map(partToBlock).filter((b): b is Anthropic.Beta.BetaContentBlockParam => b !== null);
    out.push({ role: msg.role, content });
  }
  if (out.length === 0 || out[0].role !== 'user') out.unshift({ role: 'user', content: '(start)' });
  return { system: systemParts.join('\n\n'), messages: out };
}

// ─────────────────────────────────────────────
// JSON 模式：去掉可能的 ``` 围栏，只保留最外层对象
// ─────────────────────────────────────────────

/** 流式 JSON 过滤：丢掉第一个 { 之前的内容，最外层 } 之后的内容不再输出 */
class JsonStreamFilter {
  private started = false;
  private finished = false;
  private depth = 0;
  private inString = false;
  private escaped = false;

  push(text: string): string {
    if (this.finished) return '';
    let out = '';
    for (const ch of text) {
      if (!this.started) {
        if (ch !== '{') continue;
        this.started = true;
      }
      out += ch;
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (ch === '\\') this.escaped = true;
        else if (ch === '"') this.inString = false;
        continue;
      }
      if (ch === '"') this.inString = true;
      else if (ch === '{') this.depth++;
      else if (ch === '}') {
        this.depth--;
        if (this.depth === 0) {
          this.finished = true;
          break;
        }
      }
    }
    return out;
  }
}

function extractJsonObject(text: string): string {
  const filter = new JsonStreamFilter();
  const out = filter.push(text);
  return out || text.trim();
}

// ─────────────────────────────────────────────
// 适配器：client.chat.completions.create(...)
// ─────────────────────────────────────────────

type CreateParams = {
  model?: string;
  messages: OpenAIMessage[];
  stream?: boolean;
  response_format?: { type?: string };
  max_tokens?: number;
  max_completion_tokens?: number;
};

type StreamChunk = { choices: Array<{ delta: { content?: string }; finish_reason: string | null }> };

class ClaudeChatAdapter {
  private readonly client: Anthropic;
  readonly chat: { completions: { create: (params: CreateParams) => Promise<unknown> } };

  constructor(apiKey: string) {
    this.client = new Anthropic({ apiKey: apiKey.trim() });
    this.chat = { completions: { create: (params) => this.create(params) } };
  }

  private buildRequest(params: CreateParams): Anthropic.Beta.MessageCreateParamsNonStreaming {
    const model = /^claude-/i.test(params.model?.trim() ?? '') ? params.model!.trim() : DEFAULT_CLAUDE_MODEL;
    const json = params.response_format?.type === 'json_object';
    const converted = convertMessages(params.messages ?? []);
    const systemText = [converted.system, json ? JSON_ONLY_INSTRUCTION : ''].filter(Boolean).join('\n\n');
    // Claude 的思考也计入 max_tokens：在调用方给的可见输出上限之外留出余量，避免被截断
    const requested = params.max_completion_tokens ?? params.max_tokens ?? 4000;
    const maxTokens = Math.min(64_000, Math.max(8_000, requested + 6_000));

    const body: Anthropic.Beta.MessageCreateParamsNonStreaming = {
      model,
      max_tokens: maxTokens,
      messages: converted.messages,
      // 会议实时答题对延迟敏感：低 effort
      output_config: { effort: 'low' },
      ...(systemText
        ? { system: [{ type: 'text', text: systemText, cache_control: { type: 'ephemeral' } }] }
        : {})
    };
    if (FALLBACK_MODELS.has(model)) {
      body.betas = ['server-side-fallback-2026-07-01'];
      body.fallbacks = 'default';
    }
    return body;
  }

  private async create(params: CreateParams): Promise<unknown> {
    const body = this.buildRequest(params);
    const json = params.response_format?.type === 'json_object';
    if (params.stream) return this.streamChunks(body, json);

    const stream = this.client.beta.messages.stream(body);
    const message = await stream.finalMessage();
    assertNotRefused(message);
    const text = message.content
      .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
      .map(b => b.text)
      .join('');
    return {
      choices: [
        {
          message: { role: 'assistant', content: json ? extractJsonObject(text) : text },
          finish_reason: message.stop_reason === 'max_tokens' ? 'length' : 'stop'
        }
      ]
    };
  }

  private async *streamChunks(
    body: Anthropic.Beta.MessageCreateParamsNonStreaming,
    json: boolean
  ): AsyncGenerator<StreamChunk> {
    const stream = this.client.beta.messages.stream(body);
    const filter = json ? new JsonStreamFilter() : null;
    for await (const event of stream) {
      if (event.type !== 'content_block_delta' || event.delta.type !== 'text_delta') continue;
      const text = filter ? filter.push(event.delta.text) : event.delta.text;
      if (text) yield { choices: [{ delta: { content: text }, finish_reason: null }] };
    }
    const message = await stream.finalMessage();
    assertNotRefused(message);
    yield {
      choices: [{ delta: {}, finish_reason: message.stop_reason === 'max_tokens' ? 'length' : 'stop' }]
    };
  }
}

function assertNotRefused(message: Anthropic.Beta.BetaMessage): void {
  if (message.stop_reason === 'refusal') {
    const category = message.stop_details?.category;
    throw new Error(`Claude 拒绝回答${category ? `（${category}）` : ''}`);
  }
}
