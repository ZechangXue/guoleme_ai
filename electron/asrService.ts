import fs from 'node:fs';
import path from 'node:path';
import OpenAI from 'openai';

const SAMPLE_RATE = 16000;
const CHANNELS = 1;
const BYTES_PER_SAMPLE = 2;

function pcm16ToWav(pcm: Buffer, sampleRate: number, channels: number): Buffer {
  const dataSize = pcm.length;
  const headerSize = 44;
  const buffer = Buffer.alloc(headerSize + dataSize);

  // RIFF chunk descriptor
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(headerSize + dataSize - 8, 4);
  buffer.write('WAVE', 8);

  // fmt subchunk
  buffer.write('fmt ', 12);
  buffer.writeUInt32LE(16, 16); // Subchunk1Size for PCM
  buffer.writeUInt16LE(1, 20); // AudioFormat = 1 (PCM)
  buffer.writeUInt16LE(channels, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  const byteRate = sampleRate * channels * BYTES_PER_SAMPLE;
  buffer.writeUInt32LE(byteRate, 28);
  const blockAlign = channels * BYTES_PER_SAMPLE;
  buffer.writeUInt16LE(blockAlign, 32);
  buffer.writeUInt16LE(8 * BYTES_PER_SAMPLE, 34); // bits per sample

  // data subchunk
  buffer.write('data', 36);
  buffer.writeUInt32LE(dataSize, 40);

  pcm.copy(buffer, headerSize);
  return buffer;
}

export async function transcribeSegment(
  audioBuffer: Buffer,
  apiKey: string,
  mock: boolean,
  sampleRate?: number
): Promise<string> {
  if (mock) {
    // Mock：用于开发调试
    return 'Could you briefly introduce your recent project experience?';
  }

  const client = new OpenAI({ apiKey });

  const tmpDir = path.join(process.cwd(), '.tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const tmpPath = path.join(tmpDir, `segment-${Date.now()}.wav`);
  const wavBuffer = pcm16ToWav(audioBuffer, sampleRate ?? SAMPLE_RATE, CHANNELS);
  fs.writeFileSync(tmpPath, wavBuffer);

  try {
    const file = fs.createReadStream(tmpPath);
    const res = await client.audio.transcriptions.create({
      file,
      model: 'whisper-1',
      response_format: 'json'
    });
    const text = (res as any).text || '';
    return String(text).trim();
  } finally {
    fs.unlink(tmpPath, () => {});
  }
}

/** Whisper 内部约 30s 窗口；超过后容易只转写出开头或结尾。 */
const WHISPER_CHUNK_SECONDS = 25;
const INTER_SEGMENT_SILENCE_MS = 200;
const WHISPER_PROMPT_TAIL_CHARS = 300;

export async function transcribeSegmentVerbose(
  audioBuffer: Buffer,
  apiKey: string,
  mock: boolean,
  sampleRate?: number,
  prompt?: string
): Promise<{ text: string; language?: string; duration?: number }> {
  if (mock) {
    return {
      text: 'Could you briefly introduce your recent project experience?',
      language: 'english'
    };
  }

  const client = new OpenAI({ apiKey });

  const tmpDir = path.join(process.cwd(), '.tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const tmpPath = path.join(tmpDir, `segment-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.wav`);
  const wavBuffer = pcm16ToWav(audioBuffer, sampleRate ?? SAMPLE_RATE, CHANNELS);
  fs.writeFileSync(tmpPath, wavBuffer);

  try {
    const file = fs.createReadStream(tmpPath);
    const body: Record<string, unknown> = {
      file,
      model: 'whisper-1',
      response_format: 'verbose_json'
    };
    if (prompt && prompt.trim()) body.prompt = prompt.trim();
    const res = await client.audio.transcriptions.create(body as any);
    return {
      ...textFromWhisperResponse(res),
      language: typeof (res as any).language === 'string' ? (res as any).language : undefined,
      duration: typeof (res as any).duration === 'number' ? (res as any).duration : undefined
    };
  } finally {
    fs.unlink(tmpPath, () => {});
  }
}

function textFromWhisperResponse(res: unknown): { text: string } {
  const raw = res as { text?: unknown; segments?: Array<{ text?: unknown }> };
  const fromText = String(raw?.text || '').trim();
  const fromSegments = Array.isArray(raw?.segments)
    ? raw.segments.map(s => String(s?.text ?? '')).join('').replace(/\s+/g, ' ').trim()
    : '';
  return { text: fromSegments.length > fromText.length ? fromSegments : fromText };
}

function splitPcmAligned(pcm: Buffer, maxBytes: number): Buffer[] {
  const aligned = Math.max(BYTES_PER_SAMPLE, maxBytes - (maxBytes % BYTES_PER_SAMPLE));
  const out: Buffer[] = [];
  for (let i = 0; i < pcm.length; i += aligned) {
    out.push(pcm.subarray(i, Math.min(i + aligned, pcm.length)));
  }
  return out;
}

function joinWithSilence(parts: Buffer[], silence: Buffer): Buffer {
  if (parts.length === 0) return Buffer.alloc(0);
  if (parts.length === 1) return parts[0];
  const pieces: Buffer[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i > 0) pieces.push(silence);
    pieces.push(parts[i]);
  }
  return Buffer.concat(pieces);
}

/**
 * 翻译总结专用：按约 25s 语音切块送 Whisper，避免长音频只转写出头/尾。
 * 面试/组会路径请继续用 transcribeSegment。
 */
export async function transcribeLongPcm(
  segments: Buffer[],
  apiKey: string,
  mock: boolean,
  sampleRate: number = SAMPLE_RATE
): Promise<{ text: string; language?: string }> {
  const nonempty = segments.filter(s => s.length > 0);
  if (nonempty.length === 0) return { text: '' };
  if (mock) {
    return transcribeSegmentVerbose(Buffer.concat(nonempty), apiKey, true, sampleRate);
  }

  const maxChunkBytes = Math.floor(WHISPER_CHUNK_SECONDS * sampleRate) * BYTES_PER_SAMPLE;
  const silenceBytes = Math.floor((sampleRate * INTER_SEGMENT_SILENCE_MS) / 1000) * BYTES_PER_SAMPLE;
  const silence = Buffer.alloc(silenceBytes);

  const groups: Buffer[][] = [];
  let current: Buffer[] = [];
  let currentSpeechBytes = 0;

  const flushGroup = () => {
    if (current.length === 0) return;
    groups.push(current);
    current = [];
    currentSpeechBytes = 0;
  };

  for (const seg of nonempty) {
    if (seg.length > maxChunkBytes) {
      flushGroup();
      for (const piece of splitPcmAligned(seg, maxChunkBytes)) {
        groups.push([piece]);
      }
      continue;
    }
    if (currentSpeechBytes > 0 && currentSpeechBytes + seg.length > maxChunkBytes) {
      flushGroup();
    }
    current.push(seg);
    currentSpeechBytes += seg.length;
  }
  flushGroup();

  let combined = '';
  let language: string | undefined;
  let prompt = '';

  for (let i = 0; i < groups.length; i++) {
    const pcm = joinWithSilence(groups[i], silence);
    const audioSec = pcm.length / (sampleRate * BYTES_PER_SAMPLE);
    const res = await transcribeSegmentVerbose(pcm, apiKey, false, sampleRate, prompt);
    console.log(
      `[Translate] Whisper chunk ${i + 1}/${groups.length}: audio=${audioSec.toFixed(1)}s, ` +
        `textLen=${res.text.length}, whisperDuration=${res.duration ?? '?'}`
    );
    if (res.language && !language) language = res.language;
    if (res.text) {
      combined = combined ? `${combined} ${res.text}` : res.text;
      prompt = combined.slice(-WHISPER_PROMPT_TAIL_CHARS);
    }
  }

  return { text: combined.trim(), language };
}

