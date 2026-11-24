import React, { useEffect, useState } from 'react';
import type {
  MeetingPrep,
  MeetingProfileState,
  MeetingScene,
  MeetingSession,
  MeetingTrigger
} from '../../electron/types';

export const SCENE_OPTIONS: { value: MeetingScene; label: string; hint: string }[] = [
  { value: 'weekly', label: '周组会进展', hint: '以本周进展为主要依据，回答追问时给具体结果和下一步' },
  { value: 'project', label: '新项目 / 方案探讨', hint: '思路题按结论 → 理由 → 成本 → 可行性 → 验证 → 下一步回答' },
  { value: 'partner', label: '合作方技术会谈', hint: '开启保密边界：不主动透露成本、IP、未公开计划、团队情况' },
  { value: 'interviewer', label: '面试（我是面试官）', hint: '卡片变成追问建议与评估要点' }
];

export const TRIGGER_OPTIONS: { value: MeetingTrigger; label: string; hint: string }[] = [
  { value: 'mention', label: '点到我才弹', hint: '听到你的名字 / 关键词，或 “what do you think”“over to you” 这类点名时弹卡' },
  { value: 'all', label: '所有问题都弹', hint: '每个像问题的发言都弹卡（组会里会比较频繁）' },
  { value: 'manual', label: '只按热键', hint: '只有按 Ctrl+Shift+1 或「回答刚才的问题」时才弹卡' }
];

type Tab = 'scene' | 'persona' | 'week' | 'memory';

interface Props {
  onClose: () => void;
  /** 场景 / 触发方式 / 画像 / 汇报稿变化后通知外层刷新 */
  onChanged: () => void;
}

function fmtDate(at: number): string {
  const d = new Date(at);
  return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

const MeetingPrepPanel: React.FC<Props> = ({ onClose, onChanged }) => {
  const [tab, setTab] = useState<Tab>('scene');
  const [state, setState] = useState<MeetingProfileState | null>(null);
  const [scene, setScene] = useState<MeetingScene>('weekly');
  const [trigger, setTrigger] = useState<MeetingTrigger>('mention');
  const [keywords, setKeywords] = useState('');
  const [answerLanguage, setAnswerLanguage] = useState<'en' | 'zh'>('en');
  const [persona, setPersona] = useState('');
  const [personaDirty, setPersonaDirty] = useState(false);
  const [notes, setNotes] = useState('');
  const [notesDirty, setNotesDirty] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState('');

  const reload = async () => {
    const st = await window.teleprompter.getMeetingState();
    setState(st);
    return st;
  };

  useEffect(() => {
    (async () => {
      const [st, settings] = await Promise.all([window.teleprompter.getMeetingState(), window.teleprompter.getSettings()]);
      setState(st);
      setPersona(st.personaText);
      setNotes(st.weeklyNotes);
      setScene(settings.meetingScene ?? 'weekly');
      setTrigger(settings.meetingTrigger ?? 'mention');
      setKeywords(settings.meetingTriggerKeywords ?? '');
      setAnswerLanguage(settings.answerLanguage ?? 'en');
    })();
    const off = window.teleprompter.onMeetingProfileUpdated(() => {
      reload();
    });
    return off;
  }, []);

  const flash = (text: string) => {
    setMessage(text);
    setTimeout(() => setMessage(m => (m === text ? '' : m)), 3000);
  };

  const saveSettings = async (partial: Parameters<typeof window.teleprompter.updateSettings>[0]) => {
    await window.teleprompter.updateSettings(partial);
    onChanged();
  };

  const savePersona = async () => {
    await window.teleprompter.setMeetingPersona(persona);
    setPersonaDirty(false);
    onChanged();
    flash('画像已保存');
  };

  const draftPersona = async () => {
    if (persona.trim() && !window.confirm('根据资料库文档生成画像草稿，会追加到当前画像末尾。继续？')) return;
    setBusy('persona');
    try {
      const r = await window.teleprompter.draftMeetingPersona();
      if (!r.ok) {
        alert(r.error);
        return;
      }
      setPersona(prev => (prev.trim() ? `${prev.trim()}\n\n--- 从文档生成的补充 ---\n${r.text}` : r.text));
      setPersonaDirty(true);
      flash('草稿已生成，检查无误后点「保存画像」');
    } finally {
      setBusy(null);
    }
  };

  const saveNotes = async () => {
    await window.teleprompter.setMeetingWeeklyNotes(notes);
    setNotesDirty(false);
    onChanged();
  };

  const importNotesFile = async () => {
    const r = await window.teleprompter.importMeetingNotesFile();
    if (!r.ok) {
      if (!r.canceled && r.error) alert(r.error);
      return;
    }
    const imported = (r.text ?? '').trim();
    let next = imported;
    if (notes.trim()) {
      // 默认替换（每周换一次）；取消则追加在后面
      const replace = window.confirm(`用「${r.fileName}」替换当前的本周进展？\n\n确定 = 替换，取消 = 追加到末尾`);
      next = replace ? imported : `${notes.trim()}\n\n--- ${r.fileName} ---\n${imported}`;
    }
    setNotes(next);
    await window.teleprompter.setMeetingWeeklyNotes(next);
    setNotesDirty(false);
    onChanged();
    flash(`已导入「${r.fileName}」（${imported.length} 字），可以直接修改，再点「生成汇报稿与预测追问」`);
  };

  const generatePrep = async () => {
    setBusy('prep');
    try {
      await window.teleprompter.setMeetingWeeklyNotes(notes);
      setNotesDirty(false);
      const r = await window.teleprompter.generateMeetingPrep();
      if (!r.ok) {
        alert(r.error);
        return;
      }
      await reload();
      onChanged();
      flash('汇报稿与预测追问已生成');
    } finally {
      setBusy(null);
    }
  };

  const clearPrep = async () => {
    await window.teleprompter.clearMeetingPrep();
    await reload();
    onChanged();
  };

  const endMeeting = async () => {
    setBusy('end');
    try {
      await window.teleprompter.endMeetingSession();
      await reload();
      flash('本场已结束，正在后台提炼记忆…');
    } finally {
      setBusy(null);
    }
  };

  const prep: MeetingPrep | null = state?.prep ?? null;
  const sessions: MeetingSession[] = (state?.sessions ?? []).slice().sort((a, b) => b.startedAt - a.startedAt);

  const tabs: { key: Tab; label: string }[] = [
    { key: 'scene', label: '场景 & 弹卡' },
    { key: 'persona', label: '我的画像' },
    { key: 'week', label: '本周进展' },
    { key: 'memory', label: '会议记忆' }
  ];

  return (
    <div className="panel-overlay">
      <div className="panel-header">
        <div className="panel-title">🎯 会议准备</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {message && <span className="muted" style={{ fontSize: 12, color: '#4ade80' }}>{message}</span>}
          <button className="icon-btn" onClick={onClose}>✕</button>
        </div>
      </div>

      <div className="meeting-tabs">
        {tabs.map(t => (
          <button
            key={t.key}
            className={`meeting-tab ${tab === t.key ? 'active' : ''}`}
            onClick={() => setTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="panel-body" style={{ overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 10 }}>
        {tab === 'scene' && (
          <>
            <div>
              <div className="assist-section-title">会议场景</div>
              <div className="meeting-option-grid">
                {SCENE_OPTIONS.map(o => (
                  <button
                    key={o.value}
                    className={`meeting-option ${scene === o.value ? 'active' : ''}`}
                    onClick={() => {
                      setScene(o.value);
                      saveSettings({ meetingScene: o.value });
                    }}
                  >
                    <div style={{ fontWeight: 600 }}>{o.label}</div>
                    <div className="muted" style={{ fontSize: 11 }}>{o.hint}</div>
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="assist-section-title">什么时候弹答题卡</div>
              <div className="meeting-option-grid">
                {TRIGGER_OPTIONS.map(o => (
                  <button
                    key={o.value}
                    className={`meeting-option ${trigger === o.value ? 'active' : ''}`}
                    onClick={() => {
                      setTrigger(o.value);
                      saveSettings({ meetingTrigger: o.value });
                    }}
                  >
                    <div style={{ fontWeight: 600 }}>{o.label}</div>
                    <div className="muted" style={{ fontSize: 11 }}>{o.hint}</div>
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="assist-section-title">点名关键词（逗号分隔）</div>
              <input
                className="input"
                placeholder="你的名字及转写常见误拼，如：Zechang, Ze Chang, Zachang"
                value={keywords}
                onChange={e => setKeywords(e.target.value)}
                onBlur={() => saveSettings({ meetingTriggerKeywords: keywords })}
              />
              <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>
                这些词也会作为转写提示，提高名字的识别率。
              </div>
            </div>
            <div>
              <div className="assist-section-title">回答语言</div>
              <div style={{ display: 'flex', gap: 6 }}>
                {(['en', 'zh'] as const).map(lang => (
                  <button
                    key={lang}
                    className={`meeting-option ${answerLanguage === lang ? 'active' : ''}`}
                    style={{ flex: 'none', padding: '6px 14px' }}
                    onClick={() => {
                      setAnswerLanguage(lang);
                      saveSettings({ answerLanguage: lang });
                    }}
                  >
                    {lang === 'en' ? 'English' : '中文'}
                  </button>
                ))}
              </div>
              <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>
                卡片上的「问题」和「提醒」始终是中文，方便你快速理解。
              </div>
            </div>
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.6 }}>
              快捷键（全局，焦点在 Zoom / Teams 也可用）：<span className="kbd">Ctrl+Shift+1</span> 回答刚才的问题 ·{' '}
              <span className="kbd">Ctrl+Shift+2</span> 中文 → 英文口语
            </div>
          </>
        )}

        {tab === 'persona' && (
          <>
            <div className="muted" style={{ fontSize: 12 }}>
              答题卡会以这份画像的身份、用第一人称回答。粘贴你的个人画像（角色、产品、架构、同事分工、沟通风格、原则），也可以从资料库文档生成草稿再修改。
            </div>
            <textarea
              className="textarea"
              style={{ minHeight: 180, flex: 1 }}
              value={persona}
              placeholder="例如：I'm the CTO of ..., responsible for ... Products: ... Colleagues: ..."
              onChange={e => {
                setPersona(e.target.value);
                setPersonaDirty(true);
              }}
            />
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <button className="btn" onClick={savePersona} disabled={!personaDirty}>
                保存画像
              </button>
              <button className="btn" onClick={draftPersona} disabled={busy === 'persona'}>
                {busy === 'persona' ? '生成中…' : '从资料库文档生成草稿'}
              </button>
              <span className="muted" style={{ fontSize: 11 }}>{persona.length.toLocaleString()} 字符</span>
            </div>
          </>
        )}

        {tab === 'week' && (
          <>
            <div className="muted" style={{ fontSize: 12 }}>
              用中文随手写：这周完成了什么、发现了什么（带数字）、卡在哪、下周计划、需要团队拍板的事。会上的答题卡会优先参考这里。
            </div>
            <textarea
              className="textarea"
              style={{ minHeight: 120 }}
              value={notes}
              placeholder={'1. 完成了 …\n2. 发现 …（指标 / 结果）\n3. 卡在 …\n4. 下周计划 …\n5. 需要讨论 …'}
              onChange={e => {
                setNotes(e.target.value);
                setNotesDirty(true);
              }}
              onBlur={() => notesDirty && saveNotes()}
            />
            <div style={{ display: 'flex', gap: 8 }}>
              <button className="btn" onClick={importNotesFile} title="PDF / DOCX / TXT / MD，只提取文字">
                从文件导入
              </button>
              <button className="btn" onClick={generatePrep} disabled={busy === 'prep' || !notes.trim()}>
                {busy === 'prep' ? '生成中…' : '生成汇报稿与预测追问'}
              </button>
              {prep && (
                <button className="btn" onClick={clearPrep}>
                  清除已生成内容
                </button>
              )}
            </div>

            {prep && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                <div>
                  <div className="assist-section-title">英文汇报稿（会中可在顶部展开）</div>
                  <div className="meeting-prep-block" style={{ whiteSpace: 'pre-wrap' }}>{prep.update_script_en}</div>
                </div>
                {prep.likely_questions.length > 0 && (
                  <div>
                    <div className="assist-section-title">可能被追问</div>
                    {prep.likely_questions.map((q, i) => (
                      <details key={i} className="meeting-prep-block">
                        <summary>
                          {q.asker ? <span className="meeting-chip subtle">{q.asker}</span> : null} {q.question_en}
                          {q.question_zh ? <div className="muted" style={{ fontSize: 11 }}>{q.question_zh}</div> : null}
                        </summary>
                        <div style={{ marginTop: 6, color: 'var(--color-concise, #93c5fd)' }}>{q.answer_en}</div>
                      </details>
                    ))}
                  </div>
                )}
                {prep.decisions_needed_en.length > 0 && (
                  <div>
                    <div className="assist-section-title">需要团队拍板</div>
                    <ul className="meeting-points">
                      {prep.decisions_needed_en.map((d, i) => (
                        <li key={i}>{d}</li>
                      ))}
                    </ul>
                  </div>
                )}
                <div className="muted" style={{ fontSize: 11 }}>生成于 {fmtDate(prep.generatedAt)}</div>
              </div>
            )}
          </>
        )}

        {tab === 'memory' && (
          <>
            <div className="muted" style={{ fontSize: 12 }}>
              每场会议结束后，会自动记下：被问到了什么、你怎么答的、你答应了什么。下次开会时答题卡会参考最近 3 场，保证说法前后一致。
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <button className="btn" onClick={endMeeting} disabled={busy === 'end' || !state?.activeSessionId}>
                {busy === 'end' ? '处理中…' : '结束当前会议并生成记忆'}
              </button>
              {sessions.length > 0 && (
                <button
                  className="btn"
                  onClick={async () => {
                    if (!window.confirm('确认清空全部会议记忆？')) return;
                    await window.teleprompter.clearMeetingSessions();
                    await reload();
                  }}
                >
                  清空全部
                </button>
              )}
            </div>
            {sessions.length === 0 && <div className="muted">还没有会议记录。</div>}
            {sessions.map(s => {
              const active = s.id === state?.activeSessionId;
              return (
                <div key={s.id} className="meeting-prep-block">
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontWeight: 600 }}>{fmtDate(s.startedAt)}</span>
                    <span className="meeting-chip subtle">
                      {SCENE_OPTIONS.find(o => o.value === s.scene)?.label ?? s.scene}
                    </span>
                    {active && <span className="meeting-chip">进行中</span>}
                    <span className="muted" style={{ fontSize: 11 }}>
                      {s.cards.length} 张卡片 · {s.transcript.length} 条转写
                    </span>
                    <div style={{ flex: 1 }} />
                    {!active && (
                      <button
                        className="icon-btn"
                        title="删除这条记忆"
                        onClick={async () => {
                          await window.teleprompter.deleteMeetingSession(s.id);
                          await reload();
                        }}
                      >
                        🗑
                      </button>
                    )}
                  </div>
                  {s.digest_zh ? (
                    <div style={{ whiteSpace: 'pre-wrap', marginTop: 6, fontSize: 12 }}>{s.digest_zh}</div>
                  ) : (
                    !active && (
                      <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
                        {s.cards.length === 0 && s.transcript.length < 5
                          ? '（内容太少，不生成记忆）'
                          : '记忆提炼中（失败时会在下次开始监听时重试）…'}
                      </div>
                    )
                  )}
                  {(s.commitments ?? []).length > 0 && (
                    <ul className="meeting-points" style={{ marginTop: 6 }}>
                      {(s.commitments ?? []).map((c, i) => (
                        <li key={i}>☐ {c}</li>
                      ))}
                    </ul>
                  )}
                </div>
              );
            })}
          </>
        )}
      </div>
    </div>
  );
};

export default MeetingPrepPanel;
