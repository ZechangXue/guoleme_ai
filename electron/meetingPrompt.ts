/**
 * 会议答题卡提示词组装。
 * 顺序按「稳定 → 动态」排列：system 里放画像 / 文档 / 场景 / 本周进展 / 历史记忆（整场会议基本不变，
 * 便于命中 OpenAI 自动 prompt cache）；user 里放触发方式、本场已答卡片、实时转写与最新发言。
 */
import type { MeetingScene, MeetingSession, Settings } from './types';
import { buildMeetingAnswerContext } from './retrieval';
import { getContextFiles } from './contextStore';
import {
  MEETING_ASSIST_SYSTEM_PROMPT,
  buildMeetingAssistOutputFormat
} from './sharedPrompts';
import { getMeetingProfileState, getRecentDigestedSessions, getActiveSession } from './meetingProfile';

/** 每次答题注入的项目文档上限（字符）；过大既慢又贵 */
const MEETING_DOC_MAX_CHARS = 120_000;
/** 「本周进展」注入上限：导入整份周报 PDF 时避免每张卡都带几万字 */
export const WEEKLY_NOTES_MAX_CHARS = 30_000;

export const SCENE_LABEL_ZH: Record<MeetingScene, string> = {
  weekly: '周组会进展',
  project: '新项目 / 方案探讨',
  partner: '合作方技术会谈',
  interviewer: '面试（我是面试官）'
};

const SCENE_INSTRUCTIONS: Record<MeetingScene, string> = {
  weekly: `Weekly internal team progress meeting. Participants share what they did since the last meeting, discuss results, blockers and priorities.
Expect follow-ups on my update: progress, concrete results and numbers, why I did something, blockers, timelines and next steps. Use [THIS WEEK] first, then [PAST MEETINGS] for continuity.`,
  project: `Internal discussion of a new project, feature or technical approach.
Expect "how would we do X", option comparisons, feasibility, effort and cost questions. Give a clear recommendation, then: feasibility for our small team, compute / cloud cost, fit with our existing architecture and data, validation needed, risks, and a concrete first step. Clearly label ideas as proposals.`,
  partner: `Technical meeting with an EXTERNAL partner or collaborator (not my internal team).
Confidentiality: do not volunteer internal cloud costs, budgets, pricing, unreleased product plans, IP / patent details, unpublished results, team size or hiring issues, or internal disagreements. If asked about them, give a polite, non-committal answer and explain why in caution_zh.
Use a slightly more formal tone. Emphasise validated, demonstrable capabilities; never overstate maturity or clinical validation.`,
  interviewer: `SCENE OVERRIDE — I am the INTERVIEWER assessing a candidate; the live speech is mostly the candidate.
Do NOT answer as a candidate. Reinterpret the output fields:
- question_zh: 候选人刚才在说什么 / 回答了什么（中文一句）
- q_type: "other"
- opener_en: the single best follow-up question I should ask next
- points_en: 3 short things to probe or listen for (gaps, vague claims, depth, ownership, end-to-end ability)
- concise_answer_en: my quick private assessment of that answer (strengths / concerns) — not to be said aloud
- expanded_answer_en: 2-3 further follow-up questions, deeper or more practical
- source: which part of the profile / role requirements this relates to
- caution_zh: 需要留意的红旗或核实点
Only use "无法确定问题" for pure noise.`
};

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max)}\n[... truncated ...]`;
}

/** 组会模式下额外可参考的个人资料（简历 / 项目笔记），作为文档的补充 */
function buildPersonalDocsBlock(): string {
  const files = getContextFiles().filter(
    f => (f.docType === 'resume' || f.docType === 'project_notes' || f.docType === 'qa_notes') && f.rawText
  );
  if (files.length === 0) return '';
  return files
    .map(f => `=== ${f.fileName} ===\n${(f.rawText ?? '').trim()}`)
    .join('\n\n');
}

export function buildProjectDocsBlock(maxChars = MEETING_DOC_MAX_CHARS): string {
  const meetCtx = buildMeetingAnswerContext();
  const personal = buildPersonalDocsBlock();
  const parts = [meetCtx.hasDocuments ? meetCtx.fullContent : '', personal].filter(Boolean);
  if (parts.length === 0) return '(none uploaded)';
  return truncate(parts.join('\n\n'), maxChars);
}

export function buildPastMeetingsBlock(limit = 3): string {
  const sessions = getRecentDigestedSessions(limit);
  if (sessions.length === 0) return '(none yet)';
  return sessions
    .map(s => {
      const date = new Date(s.startedAt).toISOString().slice(0, 10);
      const commitments = (s.commitments ?? []).length
        ? `\nMy commitments: ${(s.commitments ?? []).map(c => `- ${c}`).join('\n')}`
        : '';
      return `--- ${date} · ${SCENE_LABEL_ZH[s.scene] ?? s.scene} ---\n${s.digest_zh ?? ''}${commitments}`;
    })
    .join('\n\n');
}

export function buildThisWeekBlock(): string {
  const st = getMeetingProfileState();
  const notes = st.weeklyNotes.trim();
  const script = st.prep?.update_script_en?.trim();
  if (!notes && !script) return '(no notes for this week)';
  const parts: string[] = [];
  if (notes) parts.push(`My notes (raw, may be Chinese):\n${truncate(notes, WEEKLY_NOTES_MAX_CHARS)}`);
  if (script) parts.push(`My prepared spoken update:\n${script}`);
  return parts.join('\n\n');
}

export function buildPersonaBlock(maxChars?: number): string {
  const persona = getMeetingProfileState().personaText.trim();
  if (!persona) return '(not provided — rely on the documents)';
  return maxChars ? truncate(persona, maxChars) : persona;
}

export function buildMeetingSystemPrompt(settings: Settings): string {
  const scene: MeetingScene = settings.meetingScene ?? 'weekly';
  return `${MEETING_ASSIST_SYSTEM_PROMPT}

====================
[MY PROFILE]
${buildPersonaBlock()}

====================
[PROJECT DOCUMENTS]
${buildProjectDocsBlock()}

====================
[MEETING TYPE] ${SCENE_LABEL_ZH[scene]}
${SCENE_INSTRUCTIONS[scene]}

====================
[THIS WEEK]
${buildThisWeekBlock()}

====================
[PAST MEETINGS]
${buildPastMeetingsBlock()}

====================
${buildMeetingAssistOutputFormat(settings.answerLanguage)}`;
}

export type MeetingTriggerKind = 'auto' | 'mention' | 'manual' | 'screenshot';

const TRIGGER_TEXT: Record<MeetingTriggerKind, string> = {
  auto: 'auto — a question was detected in the live speech. Answer only if it is something I am expected to respond to.',
  mention: 'mention — my name or a direct cue to me was heard. Answer what I am being asked.',
  manual: 'manual — I pressed "answer now". Always answer the most recent question or topic, even if it was not addressed to me.',
  screenshot: 'screenshot — I captured the screen (slides, chat or shared doc). Treat the image as the current question / topic and answer it.'
};

function formatAgo(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')} ago`;
}

export function buildMeetingUserPrompt(opts: {
  trigger: MeetingTriggerKind;
  transcript: { text: string; at: number }[];
  utterance: string;
}): string {
  const now = Date.now();
  const session: MeetingSession | null = getActiveSession();
  const cards = (session?.cards ?? []).slice(-4);
  const cardsBlock = cards.length
    ? cards.map(c => `Q: ${c.question_zh}\nMy answer: ${c.answer}`).join('\n\n')
    : '(none)';
  const transcriptBlock = opts.transcript.length
    ? opts.transcript.map(l => `[${formatAgo(now - l.at)}] ${l.text}`).join('\n')
    : '(no transcript yet)';

  return `[TRIGGER] ${TRIGGER_TEXT[opts.trigger]}

[EARLIER IN THIS MEETING — answer cards I was shown]
${cardsBlock}

[LIVE TRANSCRIPT — other participants, oldest first]
${transcriptBlock}

[LATEST UTTERANCE]
${opts.utterance.trim() || '(see transcript / image)'}`;
}
