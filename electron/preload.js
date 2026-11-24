const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('teleprompter', {
  getSettings: () => ipcRenderer.invoke('settings:get'),
  updateSettings: (partial) => ipcRenderer.invoke('settings:update', partial),
  getApiKey: () => ipcRenderer.invoke('settings:hasApiKey'),
  hasApiKey: (provider) => ipcRenderer.invoke('settings:hasApiKey', provider),
  saveApiKeyForProvider: (provider, value) => ipcRenderer.invoke('settings:saveApiKeyForProvider', provider, value),
  setApiKey: (key) => ipcRenderer.invoke('settings:setApiKey', key),
  clearApiKey: (provider) => ipcRenderer.invoke('settings:clearApiKey', provider),
  testConnection: (provider, model) => ipcRenderer.invoke('settings:testConnection', provider, model),
  getDefaultModel: (provider) => ipcRenderer.invoke('settings:getDefaultModel', provider),
  regenerateSystemPrompt: () => ipcRenderer.invoke('settings:regenerateSystemPrompt'),

  addContextFile: (filePath, label) =>
    ipcRenderer.invoke('context:addFile', { filePath, label }),
  getContextFiles: () => ipcRenderer.invoke('context:getFiles'),
  clearContext: () => ipcRenderer.invoke('context:clear'),
  clearQuestionsHistory: () => ipcRenderer.invoke('context:clearHistory'),

  pickContextFile: () => ipcRenderer.invoke('dialog:pickContextFile'),

  onContextUpdated: (callback) => {
    ipcRenderer.on('context:updated', () => callback());
  },

  startListening: () => ipcRenderer.invoke('listener:start'),
  stopListening: () => ipcRenderer.invoke('listener:stop'),
  toggleListening: () => ipcRenderer.invoke('listener:toggle'),
  getListenerStatus: () => ipcRenderer.invoke('listener:status'),
  answerFromScreenshot: () => ipcRenderer.invoke('screenshot:answer'),
  answerFromFullScreenScreenshot: () => ipcRenderer.invoke('screenshot:answerFullScreen'),

  hideWindow: () => ipcRenderer.invoke('window:hide'),
  showWindow: () => ipcRenderer.invoke('window:show'),
  quitApp: () => ipcRenderer.invoke('app:quit'),

  onAssist: (callback) => {
    ipcRenderer.on('assist:newSuggestion', (_event, payload) => {
      callback(payload);
    });
  },

  onAssistStream: (callback) => {
    ipcRenderer.on('assist:streamChunk', (_event, chunk) => {
      callback(chunk);
    });
  },

  // Audio devices
  getInputDevices: () => ipcRenderer.invoke('audio:getInputDevices'),
  getAutoDeviceName: () => ipcRenderer.invoke('audio:getAutoDeviceName'),
  openSystemSoundSettings: () => ipcRenderer.invoke('audio:openSystemSoundSettings'),

  onAudioLevel: (callback) => {
    ipcRenderer.on('audio:level', (_event, level) => callback(level));
  },

  getReadableAnswer: (questionZh, contextFromConcise, options) =>
    ipcRenderer.invoke('assist:getReadableAnswer', questionZh, contextFromConcise, options),
  persistExpandedFromCard: (payload) => ipcRenderer.invoke('assist:persistExpandedFromCard', payload),

  exportInterviewSession: () => ipcRenderer.invoke('interview:exportSessionPdf'),
  prepareInterviewSessionExport: () => ipcRenderer.invoke('interview:prepareSessionExportPdf'),
  finalizeInterviewSessionExport: (tempPdfPath) =>
    ipcRenderer.invoke('interview:finalizeSessionExportPdf', tempPdfPath),

  // 组会/项目介绍模式
  analyzeMeetingDocuments: () => ipcRenderer.invoke('meeting:analyzeDocuments'),
  clearMeetingDocuments: () => ipcRenderer.invoke('meeting:clearDocuments'),

  // 会议助手：画像 / 本周进展 / 会前准备 / 会中交互 / 跨会议记忆
  getMeetingState: () => ipcRenderer.invoke('meeting:getState'),
  setMeetingPersona: (text) => ipcRenderer.invoke('meeting:setPersona', text),
  setMeetingWeeklyNotes: (text) => ipcRenderer.invoke('meeting:setWeeklyNotes', text),
  importMeetingNotesFile: () => ipcRenderer.invoke('meeting:importNotesFile'),
  generateMeetingPrep: () => ipcRenderer.invoke('meeting:generatePrep'),
  clearMeetingPrep: () => ipcRenderer.invoke('meeting:clearPrep'),
  draftMeetingPersona: () => ipcRenderer.invoke('meeting:draftPersona'),
  meetingQuickTranslate: (text) => ipcRenderer.invoke('meeting:quickTranslate', text),
  meetingAnswerNow: () => ipcRenderer.invoke('meeting:answerNow'),
  endMeetingSession: () => ipcRenderer.invoke('meeting:endSession'),
  deleteMeetingSession: (id) => ipcRenderer.invoke('meeting:deleteSession', id),
  clearMeetingSessions: () => ipcRenderer.invoke('meeting:clearSessions'),
  onMeetingCard: (callback) => {
    const handler = (_e, data) => callback(data);
    ipcRenderer.on('meeting:cardChunk', handler);
    return () => ipcRenderer.removeListener('meeting:cardChunk', handler);
  },
  onMeetingTranscript: (callback) => {
    const handler = (_e, line) => callback(line);
    ipcRenderer.on('meeting:transcript', handler);
    return () => ipcRenderer.removeListener('meeting:transcript', handler);
  },
  onMeetingTranscriptReset: (callback) => {
    const handler = (_e, lines) => callback(lines);
    ipcRenderer.on('meeting:transcriptReset', handler);
    return () => ipcRenderer.removeListener('meeting:transcriptReset', handler);
  },
  onMeetingProfileUpdated: (callback) => {
    const handler = () => callback();
    ipcRenderer.on('meeting:profileUpdated', handler);
    return () => ipcRenderer.removeListener('meeting:profileUpdated', handler);
  },
  onMeetingOpenQuickBox: (callback) => {
    const handler = () => callback();
    ipcRenderer.on('meeting:openQuickBox', handler);
    return () => ipcRenderer.removeListener('meeting:openQuickBox', handler);
  },

  // 翻译总结模式
  translateStart: () => ipcRenderer.invoke('translate:start'),
  translateStop: () => ipcRenderer.invoke('translate:stop'),
  translateSummarize: (options) => ipcRenderer.invoke('translate:summarize', options),
  onTranslateChunk: (callback) => {
    const handler = (_e, data) => callback(data);
    ipcRenderer.on('translate:chunk', handler);
    return () => ipcRenderer.removeListener('translate:chunk', handler);
  },

  // ── Mac 音频引导（仅 darwin 平台有效，Windows 调用会静默失败） ──────────
  macCheckBlackHole: () => ipcRenderer.invoke('mac:checkBlackHole'),
  macCheckMultiOutput: () => ipcRenderer.invoke('mac:checkMultiOutput'),
  macSetupDone: () => ipcRenderer.invoke('mac:setupDone'),
  macMarkSetupDone: () => ipcRenderer.invoke('mac:markSetupDone'),
  macOpenAudioMidiSetup: () => ipcRenderer.invoke('mac:openAudioMidiSetup'),
  macOpenSoundPreferences: () => ipcRenderer.invoke('mac:openSoundPreferences'),
  macOpenExternalUrl: (url) => ipcRenderer.invoke('mac:openExternalUrl', url),
  getPlatform: () => process.platform,  // 直接读取，无需 IPC，跨平台安全
});

