import React, { useEffect, useRef, useState } from 'react';

interface Result {
  input: string;
  say: string;
  shorter: string;
}

/** 会中快捷框：中文想法 → 可以直接说出口的英文（Ctrl+Shift+2） */
const QuickEnBox: React.FC<{ onClose: () => void }> = ({ onClose }) => {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [results, setResults] = useState<Result[]>([]);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const submit = async () => {
    const input = text.trim();
    if (!input || busy) return;
    setBusy(true);
    setError('');
    try {
      const r = await window.teleprompter.meetingQuickTranslate(input);
      if (r.ok) {
        setResults(prev => [{ input, say: r.say, shorter: r.shorter }, ...prev].slice(0, 4));
        setText('');
      } else {
        setError(r.error);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      inputRef.current?.focus();
    }
  };

  return (
    <div className="quick-en-box" onKeyDown={e => e.key === 'Escape' && onClose()}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <div className="panel-title" style={{ flex: 1 }}>中文想法 → 英文口语</div>
        <button className="icon-btn" onClick={onClose} title="关闭（Esc）">✕</button>
      </div>
      <textarea
        ref={inputRef}
        className="textarea"
        rows={2}
        placeholder="用中文写你想说的，例如：这个要等 Berke 那边标注好才能验证（Enter 生成，Shift+Enter 换行）"
        value={text}
        onChange={e => setText(e.target.value)}
        onKeyDown={e => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            submit();
          }
        }}
      />
      {busy && <div className="muted" style={{ fontSize: 12 }}>生成中…</div>}
      {error && <div className="meeting-caution">{error}</div>}
      <div style={{ overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 8, minHeight: 0 }}>
        {results.map((r, i) => (
          <div key={i} className="quick-en-result" style={{ opacity: i === 0 ? 1 : 0.6 }}>
            <div className="muted" style={{ fontSize: 11 }}>{r.input}</div>
            <div className="meeting-opener">{r.say}</div>
            {r.shorter && <div className="assist-thinking" style={{ fontSize: 12 }}>短版：{r.shorter}</div>}
          </div>
        ))}
      </div>
    </div>
  );
};

export default QuickEnBox;
