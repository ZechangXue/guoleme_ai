import React, { useEffect, useState } from 'react';
import type { MeetingCardData, MeetingScene } from '../../electron/types';

export interface MeetingCardState {
  id: number;
  data: MeetingCardData;
  streaming: boolean;
  error?: string;
  trigger?: string;
}

interface Props {
  card: MeetingCardState;
  scene: MeetingScene;
  index: number;
  total: number;
  onPrev?: () => void;
  onNext?: () => void;
  onClose: () => void;
  onRetry?: () => void;
}

const Q_TYPE_ZH: Record<string, string> = {
  progress: '进展',
  reasoning: '思路',
  detail: '细节',
  challenge: '质疑',
  opinion: '观点',
  other: '其他'
};

const TRIGGER_ZH: Record<string, string> = {
  auto: '自动',
  mention: '点名',
  manual: '手动',
  screenshot: '截图'
};

const Cursor: React.FC = () => (
  <span
    style={{
      display: 'inline-block',
      width: 2,
      height: '1em',
      background: 'currentColor',
      marginLeft: 2,
      verticalAlign: 'text-bottom',
      animation: 'blink 0.8s step-end infinite'
    }}
  />
);

const MeetingCard: React.FC<Props> = ({ card, scene, index, total, onPrev, onNext, onClose, onRetry }) => {
  const [showExpanded, setShowExpanded] = useState(false);
  useEffect(() => setShowExpanded(false), [card.id]);

  const d = card.data;
  const interviewer = scene === 'interviewer';
  const labels = interviewer
    ? { opener: '建议追问', points: '关注点', concise: '我的评估（不用说出口）', expanded: '更多追问' }
    : { opener: '开口一句', points: '要点', concise: '可直接说', expanded: '展开说' };
  const points = Array.isArray(d.points_en) ? d.points_en.filter(Boolean) : [];
  const qType = d.q_type ? Q_TYPE_ZH[d.q_type.trim()] ?? d.q_type : '';

  return (
    <div className="assist-card meeting-card">
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
        {qType && !interviewer && <span className="meeting-chip">{qType}</span>}
        {card.trigger && <span className="meeting-chip subtle">{TRIGGER_ZH[card.trigger] ?? card.trigger}</span>}
        <div className="assist-question" style={{ flex: 1 }}>
          {d.question_zh || <span className="muted">识别问题中…</span>}
        </div>
        {total > 1 && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 2, flexShrink: 0 }}>
            <button className="icon-btn" onClick={onPrev} disabled={index === 0} title="上一张">‹</button>
            <span className="muted" style={{ fontSize: 11 }}>{index + 1}/{total}</span>
            <button className="icon-btn" onClick={onNext} disabled={index >= total - 1} title="下一张">›</button>
          </div>
        )}
        <button className="icon-btn" onClick={onClose} title="收起卡片（Space）" style={{ flexShrink: 0 }}>
          ✕
        </button>
      </div>

      {d.opener_en ? (
        <div>
          <div className="assist-section-title">{labels.opener}</div>
          <div className="meeting-opener">
            {d.opener_en}
            {card.streaming && points.length === 0 && <Cursor />}
          </div>
        </div>
      ) : card.streaming ? (
        <div className="muted" style={{ fontSize: 13 }}>生成中…</div>
      ) : null}

      {points.length > 0 && (
        <div>
          <div className="assist-section-title">{labels.points}</div>
          <ul className="meeting-points">
            {points.map((p, i) => (
              <li key={i}>{p}</li>
            ))}
          </ul>
        </div>
      )}

      {d.concise_answer_en && (
        <div>
          <div className="assist-section-title">{labels.concise}</div>
          <div className="assist-thinking" style={{ color: 'var(--color-concise, #93c5fd)' }}>
            {d.concise_answer_en}
            {card.streaming && !d.expanded_answer_en && <Cursor />}
          </div>
        </div>
      )}

      {d.expanded_answer_en && (
        <div>
          <button
            className="btn"
            style={{ fontSize: 11, padding: '3px 8px' }}
            onClick={() => setShowExpanded(v => !v)}
          >
            {showExpanded ? `收起${labels.expanded}` : `${labels.expanded} ▾`}
          </button>
          {showExpanded && (
            <div className="assist-thinking" style={{ marginTop: 6, lineHeight: 1.6 }}>
              {d.expanded_answer_en}
              {card.streaming && <Cursor />}
            </div>
          )}
        </div>
      )}

      {(d.source || d.caution_zh) && (
        <div className="meeting-footer">
          {d.source && <div>依据：{d.source}</div>}
          {d.caution_zh && <div className="meeting-caution">⚠ {d.caution_zh}</div>}
        </div>
      )}

      {card.error && (
        <div className="meeting-caution" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ flex: 1 }}>生成失败：{card.error}</span>
          {onRetry && (
            <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }} onClick={onRetry}>
              重试
            </button>
          )}
        </div>
      )}
    </div>
  );
};

export default MeetingCard;
