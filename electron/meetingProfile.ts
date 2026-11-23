/**
 * 会议助手的本地持久化：我的画像、本周进展、会前准备结果、跨会议记忆。
 * 存放在 userData/meeting-profile.json，与面试资料库 context.json 分开。
 */
import { app } from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import { v4 as uuidv4 } from 'uuid';
import type {
  MeetingPrep,
  MeetingProfileState,
  MeetingScene,
  MeetingSession,
  MeetingSessionCard
} from './types';

const PROFILE_FILE = path.join(app.getPath('userData'), 'meeting-profile.json');

/** 最多保留的历史会议数 */
const MAX_SESSIONS = 20;
/** 单场会议最多保留的转写行（用于会后提炼记忆） */
const MAX_SESSION_TRANSCRIPT_LINES = 600;
/** 距上次活动超过该时长，再开始监听即视为新的一场会议 */
export const SESSION_IDLE_GAP_MS = 2 * 60 * 60 * 1000;

let cache: MeetingProfileState | null = null;
let writeTimer: ReturnType<typeof setTimeout> | null = null;

function emptyState(): MeetingProfileState {
  return { personaText: '', weeklyNotes: '', prep: null, sessions: [], activeSessionId: null };
}

function load(): MeetingProfileState {
  if (cache) return cache;
  try {
    const raw = JSON.parse(fs.readFileSync(PROFILE_FILE, 'utf-8'));
    cache = { ...emptyState(), ...raw };
  } catch {
    cache = emptyState();
  }
  if (!Array.isArray(cache!.sessions)) cache!.sessions = [];
  return cache!;
}

function writeNow() {
  if (!cache) return;
  fs.mkdirSync(path.dirname(PROFILE_FILE), { recursive: true });
  fs.writeFileSync(PROFILE_FILE, JSON.stringify(cache, null, 2), 'utf-8');
}

/** 转写会频繁追加，合并写盘 */
function scheduleWrite() {
  if (writeTimer) return;
  writeTimer = setTimeout(() => {
    writeTimer = null;
    writeNow();
  }, 2000);
}

export function flushMeetingProfile() {
  if (writeTimer) {
    clearTimeout(writeTimer);
    writeTimer = null;
  }
  writeNow();
}

export function getMeetingProfileState(): MeetingProfileState {
  return load();
}

export function setPersonaText(text: string) {
  load().personaText = text;
  writeNow();
}

export function setWeeklyNotes(text: string) {
  load().weeklyNotes = text;
  writeNow();
}

export function setMeetingPrep(prep: MeetingPrep | null) {
  load().prep = prep;
  writeNow();
}

// ── 会议会话（跨会议记忆的原始数据） ─────────────────────────

export function getActiveSession(): MeetingSession | null {
  const s = load();
  if (!s.activeSessionId) return null;
  return s.sessions.find(x => x.id === s.activeSessionId) ?? null;
}

/** 开始监听时调用：沿用未结束且最近活跃的会话，否则新建 */
export function ensureActiveSession(scene: MeetingScene): MeetingSession {
  const s = load();
  const active = getActiveSession();
  const now = Date.now();
  if (active && !active.endedAt && now - active.lastActiveAt < SESSION_IDLE_GAP_MS) {
    active.scene = scene;
    active.lastActiveAt = now;
    scheduleWrite();
    return active;
  }
  if (active && !active.endedAt) active.endedAt = active.lastActiveAt;
  dropIfEmpty(active);
  const session: MeetingSession = {
    id: uuidv4(),
    scene,
    startedAt: now,
    lastActiveAt: now,
    cards: [],
    transcript: []
  };
  s.sessions.push(session);
  s.activeSessionId = session.id;
  pruneSessions();
  writeNow();
  return session;
}

export function appendSessionTranscript(text: string, at: number) {
  const active = getActiveSession();
  if (!active) return;
  active.transcript.push({ text, at });
  if (active.transcript.length > MAX_SESSION_TRANSCRIPT_LINES) {
    active.transcript = active.transcript.slice(-MAX_SESSION_TRANSCRIPT_LINES);
  }
  active.lastActiveAt = at;
  scheduleWrite();
}

export function appendSessionCard(card: MeetingSessionCard) {
  const active = getActiveSession();
  if (!active) return;
  active.cards.push(card);
  active.lastActiveAt = card.at;
  scheduleWrite();
}

/** 结束当前会议；返回被结束的会话（供提炼记忆） */
export function endActiveSession(): MeetingSession | null {
  const s = load();
  const active = getActiveSession();
  s.activeSessionId = null;
  if (active && !active.endedAt) active.endedAt = Date.now();
  dropIfEmpty(active);
  writeNow();
  return active;
}

/** 没有任何转写和卡片的会话没有保留价值 */
function dropIfEmpty(session: MeetingSession | null) {
  if (!session || session.cards.length > 0 || session.transcript.length > 0) return;
  const s = load();
  s.sessions = s.sessions.filter(x => x.id !== session.id);
}

export function setSessionDigest(id: string, digest_zh: string, commitments: string[]) {
  const session = load().sessions.find(x => x.id === id);
  if (!session) return;
  session.digest_zh = digest_zh;
  session.commitments = commitments;
  writeNow();
}

export function deleteSession(id: string) {
  const s = load();
  s.sessions = s.sessions.filter(x => x.id !== id);
  if (s.activeSessionId === id) s.activeSessionId = null;
  writeNow();
}

export function clearSessions() {
  const s = load();
  s.sessions = [];
  s.activeSessionId = null;
  writeNow();
}

/** 已结束但还没提炼记忆、且有内容的会话 */
export function getUndigestedEndedSessions(): MeetingSession[] {
  const s = load();
  return s.sessions.filter(
    x => x.id !== s.activeSessionId && !x.digest_zh && (x.cards.length > 0 || x.transcript.length >= 5)
  );
}

/** 提示词用：最近几场已提炼的会议记忆 */
export function getRecentDigestedSessions(limit = 3): MeetingSession[] {
  const s = load();
  return s.sessions
    .filter(x => x.id !== s.activeSessionId && x.digest_zh)
    .sort((a, b) => b.startedAt - a.startedAt)
    .slice(0, limit);
}

function pruneSessions() {
  const s = load();
  if (s.sessions.length <= MAX_SESSIONS) return;
  s.sessions = s.sessions
    .sort((a, b) => a.startedAt - b.startedAt)
    .slice(-MAX_SESSIONS);
}
