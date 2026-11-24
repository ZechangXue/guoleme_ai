/**
 * 多 API 服务商配置：默认模型、OpenAI 兼容 baseURL、Realtime 模型名
 */
import type { ApiProvider } from './types';

/** 各服务商「instant」档默认模型（OpenAI 对应 gpt-5-mini） */
export const DEFAULT_MODEL_BY_PROVIDER: Record<ApiProvider, string> = {
  openai: 'gpt-5-mini',
  anthropic: 'claude-opus-5-5',
  google: 'gemini-2.0-flash',
  deepseek: 'deepseek-chat',
  qwen: 'qwen-turbo',
  ollama: 'llama3.2'
};

/** RAG / 文档结构化等非实时任务的便宜模型 */
export const DEFAULT_RAG_MODEL = 'gpt-5-nano';

/** OpenAI 兼容 API 的 baseURL（OpenAI 用默认即可） */
export function getOpenAICompatibleBaseUrl(provider: ApiProvider): string | undefined {
  switch (provider) {
    case 'openai':
      return undefined;
    case 'deepseek':
      return 'https://api.deepseek.com';
    case 'qwen':
      return 'https://dashscope.aliyuncs.com/compatible-mode/v1';
    default:
      return undefined;
  }
}

/**
 * 是否走 chat completions 形状的调用（OpenAI SDK）。
 * anthropic 也走这条路：createChatClient 会把 Claude Key 交给 Anthropic SDK 适配器（见 claudeChat.ts）。
 */
export function isOpenAICompatible(provider: ApiProvider): boolean {
  return provider === 'openai' || provider === 'anthropic' || provider === 'deepseek' || provider === 'qwen';
}

/** 当前仅 OpenAI 支持 Realtime 语音；其它服务商勾选 Realtime 时用流式 Chat 等效 */
export function getRealtimeModelOrNull(provider: ApiProvider): string | null {
  if (provider === 'openai') return 'gpt-realtime-mini';
  return null;
}

/** GPT-5 系列（含 gpt-5.4-*）：Chat Completions 参数与 4.x 不同 */
export function isGpt5FamilyModel(model: string): boolean {
  return /^gpt-5/i.test(model.trim());
}

/**
 * 按模型组装 chat.completions 公共参数。
 * GPT-5：省略 temperature、用 max_completion_tokens、加 reasoning_effort（压延迟）。
 * 其它模型：保持 temperature / max_tokens 行为不变。
 * 返回 any：openai@4 SDK 类型尚未完全覆盖 GPT-5 的 reasoning_effort / max_completion_tokens。
 */
export function openaiChatModelOptions(
  model: string,
  opts: {
    temperature?: number;
    maxTokens?: number;
    json?: boolean;
    stream?: boolean;
  } = {}
): any {
  const out: Record<string, unknown> = { model };
  if (opts.stream) out.stream = true;
  if (opts.json) out.response_format = { type: 'json_object' };

  if (isGpt5FamilyModel(model)) {
    // gpt-5 / gpt-5-mini / gpt-5-nano：minimal；gpt-5.x（如 5.4）支持 none
    out.reasoning_effort = /^gpt-5\./i.test(model.trim()) ? 'none' : 'minimal';
    if (opts.maxTokens != null) out.max_completion_tokens = opts.maxTokens;
  } else {
    if (opts.temperature != null) out.temperature = opts.temperature;
    if (opts.maxTokens != null) out.max_tokens = opts.maxTokens;
  }
  return out;
}
