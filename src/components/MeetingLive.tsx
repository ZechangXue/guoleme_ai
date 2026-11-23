import React, { useEffect, useRef, useState } from 'react';
import type { MeetingPrep, MeetingTranscriptLine } from '../../electron/types';

function clock(at: number): string {
  const d = new Date(at);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** 实时转写列表（自动滚到底部；用户上翻时不打扰） */
export const TranscriptList: React.FC<{ lines: MeetingTranscriptLine[]; maxHeight?: number | string; emptyText?: string }> = ({
  lines,
  maxHeight,
  emptyText = '开始监听后，对方的发言会实时显示在这里'
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);

  useEffect(() => {
    const el = ref.current;
    if (el && stickRef.current) el.scrollTop = el.scrollHeight;
  }, [lines]);

  return (
    <div
      ref={ref}
      className="meeting-transcript"
      style={maxHeight !== undefined ? { maxHeight, flex: 'none' } : undefined}
      onScroll={e => {
        const el = e.currentTarget;
        stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
      }}
    >
      {lines.length === 0 ? (
        <div className="muted" style={{ fontSize: 12, textAlign: 'center', padding: 8 }}>{emptyText}</div>
      ) : (
        lines.map(l => (
          <div key={l.id} className="meeting-transcript-line">
            <span className="muted">{clock(l.at)}</span> {l.text}
          </div>
        ))
      )}
    </div>
  );
};

/** 周组会：固定在顶部的「我的汇报稿」 */
export const MyUpdateStrip: React.FC<{ prep: MeetingPrep | null }> = ({ prep }) => {
  const [open, setOpen] = useState(false);
  if (!prep || !prep.update_script_en) return null;
  return (
    <div className="meeting-update-strip">
      <button className="meeting-update-toggle" onClick={() => setOpen(v => !v)}>
        📝 我的汇报稿 {open ? '▴' : '▾'}
      </button>
      {open && (
        <div className="meeting-update-body">
          <div style={{ whiteSpace: 'pre-wrap' }}>{prep.update_script_en}</div>
          {prep.decisions_needed_en.length > 0 && (
            <>
              <div className="assist-section-title" style={{ marginTop: 8 }}>需要团队拍板</div>
              <ul className="meeting-points">
                {prep.decisions_needed_en.map((q, i) => (
                  <li key={i}>{q}</li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}
    </div>
  );
};

/** 组会模式（无卡片时）的主视图 */
export const MeetingLiveView: React.FC<{
  lines: MeetingTranscriptLine[];
  prep: MeetingPrep | null;
  showUpdate: boolean;
  sceneLabel: string;
  triggerLabel: string;
  listening: boolean;
  cardCount: number;
  onAnswerNow: () => void;
  onShowCards: () => void;
  onEndMeeting: () => void;
}> = ({ lines, prep, showUpdate, sceneLabel, triggerLabel, listening, cardCount, onAnswerNow, onShowCards, onEndMeeting }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 8, flex: 1, minHeight: 0 }}>
    {showUpdate && <MyUpdateStrip prep={prep} />}
    <MeetingActionRow
      sceneLabel={sceneLabel}
      triggerLabel={triggerLabel}
      cardCount={cardCount}
      onAnswerNow={onAnswerNow}
      onShowCards={onShowCards}
      onEndMeeting={onEndMeeting}
    />
    <TranscriptList
      lines={lines}
      emptyText={listening ? '正在听…对方的发言会实时显示在这里' : '点击右上角「开始监听」进入会议'}
    />
  </div>
);

export const MeetingActionRow: React.FC<{
  sceneLabel: string;
  triggerLabel: string;
  cardCount: number;
  onAnswerNow: () => void;
  onShowCards: () => void;
  onEndMeeting: () => void;
}> = ({ sceneLabel, triggerLabel, cardCount, onAnswerNow, onShowCards, onEndMeeting }) => (
  <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexShrink: 0, flexWrap: 'wrap' }}>
    <span className="meeting-chip subtle" title="会议场景（在 🎯 会议准备里切换）">{sceneLabel}</span>
    <span className="meeting-chip subtle" title="弹卡方式（在 🎯 会议准备里切换）">{triggerLabel}</span>
    <div style={{ flex: 1 }} />
    <button className="btn" style={{ fontSize: 12, padding: '4px 10px' }} onClick={onAnswerNow} title="根据最近的发言生成答题卡（Ctrl+Shift+1）">
      🙋 回答刚才的问题
    </button>
    {cardCount > 0 && (
      <button className="btn" style={{ fontSize: 12, padding: '4px 10px' }} onClick={onShowCards} title="查看本场的答题卡">
        卡片 {cardCount}
      </button>
    )}
    <button className="btn" style={{ fontSize: 12, padding: '4px 10px' }} onClick={onEndMeeting} title="结束本场会议，并在后台提炼记忆供下次会议使用">
      结束本场
    </button>
  </div>
);
