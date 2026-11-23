import { app } from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import keytar from 'keytar';
import { type Settings, type ResponseStyle, type ApiProvider } from './types';
import { DEFAULT_SYSTEM_PROMPT as SHARED_DEFAULT_SYSTEM_PROMPT } from './sharedPrompts';

const SERVICE_NAME = 'InterviewTeleprompterAI';
const ACCOUNT_API_KEY = 'openai_api_key'; // 兼容旧版；新 key 存 openai_api_key

function keytarAccount(provider: ApiProvider): string {
  if (provider === 'ollama') return '';
  return `${provider}_api_key`;
}

const DEFAULT_SYSTEM_PROMPT = SHARED_DEFAULT_SYSTEM_PROMPT;

const DEFAULT_SETTINGS: Settings = {
  apiProvider: 'openai',
  model: 'gpt-5-mini',
  systemPrompt: DEFAULT_SYSTEM_PROMPT,
  mockAsr: false,
  mockLlm: false,
  listening: false,
  useRealtimeAsr: false,
  useStreamingLlm: true,
  /** 默认：Realtime 一体（音频直进模型）；与 useRealtimeAsr 互斥 */
  useRealtimeAllInOne: true,
  responseStyle: 'concise' as ResponseStyle,
  audioDeviceId: -1,
  windowOpacity: 0.95,
  ollamaBaseUrl: 'http://localhost:11434',
  /** 默认开启：下一题自动关旧卡并继续听 */
  autoDismissCardOnNewQuestion: true,
  meetingMode: false,
  answerLanguage: 'en' as const,
  translateMode: false,
  meetingScene: 'weekly',
  meetingTrigger: 'mention',
  meetingTriggerKeywords: ''
};

const SETTINGS_FILE = path.join(app.getPath('userData'), 'settings.json');

function readSettingsFile(): Partial<Settings> {
  try {
    const raw = fs.readFileSync(SETTINGS_FILE, 'utf-8');
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function writeSettingsFile(settings: Settings) {
  fs.mkdirSync(path.dirname(SETTINGS_FILE), { recursive: true });
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2), 'utf-8');
}

let cachedSettings: Settings | null = null;

export function getSettings(): Settings {
  if (!cachedSettings) {
    const fileSettings = readSettingsFile();
    cachedSettings = { ...DEFAULT_SETTINGS, ...fileSettings };
    if ((cachedSettings as any).apiProvider == null) (cachedSettings as any).apiProvider = 'openai';
    if ((cachedSettings as any).windowOpacity == null) (cachedSettings as any).windowOpacity = DEFAULT_SETTINGS.windowOpacity;
    if ((cachedSettings as any).ollamaBaseUrl == null) (cachedSettings as any).ollamaBaseUrl = DEFAULT_SETTINGS.ollamaBaseUrl;
    if ((cachedSettings as any).autoDismissCardOnNewQuestion == null) {
      (cachedSettings as any).autoDismissCardOnNewQuestion = DEFAULT_SETTINGS.autoDismissCardOnNewQuestion;
    }
    if (
      cachedSettings.model === 'instant' ||
      cachedSettings.model === 'gpt-4.1-mini'
    ) {
      cachedSettings.model = 'gpt-5-mini';
      writeSettingsFile(cachedSettings);
    }
    // 流式输出已固定开启，设置页不再提供开关
    cachedSettings.useStreamingLlm = true;
  }
  return cachedSettings;
}

export function updateSettings(partial: Partial<Settings>): Settings {
  const merged = { ...getSettings(), ...partial, useStreamingLlm: true };
  cachedSettings = merged;
  writeSettingsFile(merged);
  return merged;
}

/** 按服务商保存 Key（Ollama 为 base URL，写入 settings） */
export async function saveApiKeyForProvider(provider: ApiProvider, value: string): Promise<void> {
  if (provider === 'ollama') {
    updateSettings({ ollamaBaseUrl: value.trim() });
    return;
  }
  const account = keytarAccount(provider);
  if (account) await keytar.setPassword(SERVICE_NAME, account, value);
}

/** 当前选中服务商的 Key 或 Ollama URL；兼容旧版（仅 openai 时读 openai_api_key 或旧 key） */
export async function getApiKey(provider?: ApiProvider): Promise<string | null> {
  const p = provider ?? getSettings().apiProvider;
  if (p === 'ollama') return getSettings().ollamaBaseUrl?.trim() || null;
  const account = keytarAccount(p);
  if (!account) return null;
  let key = await keytar.getPassword(SERVICE_NAME, account);
  if (p === 'openai' && !key) key = await keytar.getPassword(SERVICE_NAME, ACCOUNT_API_KEY);
  return key || null;
}

/** 是否有当前（或指定）服务商的 Key / Ollama 地址 */
export async function hasApiKey(provider?: ApiProvider): Promise<boolean> {
  const k = await getApiKey(provider);
  return !!k?.trim();
}

/** 兼容旧 API：保存到当前选中服务商 */
export async function saveApiKey(apiKey: string): Promise<void> {
  await saveApiKeyForProvider(getSettings().apiProvider, apiKey);
}

export async function clearApiKey(provider?: ApiProvider): Promise<void> {
  const p = provider ?? getSettings().apiProvider;
  if (p === 'ollama') {
    updateSettings({ ollamaBaseUrl: '' });
    return;
  }
  const account = keytarAccount(p);
  if (account) await keytar.deletePassword(SERVICE_NAME, account);
  if (p === 'openai') await keytar.deletePassword(SERVICE_NAME, ACCOUNT_API_KEY);
}

