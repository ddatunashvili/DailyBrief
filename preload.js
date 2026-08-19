// Bridge between the brief page and the main process.
// When this API is absent (plain browser / web artifact), the page
// falls back to embedded data + localStorage.

const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('dailybrief', {
  listDays: () => ipcRenderer.invoke('brief:listDays'),
  loadDay: (date) => ipcRenderer.invoke('brief:loadDay', date),
  loadDone: (date) => ipcRenderer.invoke('brief:loadDone', date),
  saveDone: (date, state) => ipcRenderer.invoke('brief:saveDone', date, state),
  replan: () => ipcRenderer.invoke('brief:replan'),
  plansLoad: () => ipcRenderer.invoke('plans:load'),
  plansSave: (items) => ipcRenderer.invoke('plans:save', items),
  kanbanLoad: () => ipcRenderer.invoke('kanban:load'),
  kanbanSave: (data) => ipcRenderer.invoke('kanban:save', data),
  kanbanCheck: () => ipcRenderer.invoke('kanban:check'),
  aiStatus: () => ipcRenderer.invoke('ai:status'),
  onAiStatus: (cb) => ipcRenderer.on('ai:status', (ev, state) => cb(state)),
  analyticsData: () => ipcRenderer.invoke('analytics:data'),
  pickFolder: () => ipcRenderer.invoke('dialog:pickFolder'),
  taskCheck: (id) => ipcRenderer.invoke('kanban:taskCheck', id),
  taskReplan: (id) => ipcRenderer.invoke('kanban:taskReplan', id),
  dirInfo: (p) => ipcRenderer.invoke('path:dirInfo', p),
  getPathForFile: (file) => {
    try { return webUtils.getPathForFile(file); } catch (e) { return null; }
  },
  aiRuns: () => ipcRenderer.invoke('ai:runs'),
  aiKill: (runId) => ipcRenderer.invoke('ai:kill', runId),
  aiOpenContext: () => ipcRenderer.invoke('ai:openContext'),
  scanFolder: (taskId, dir) => ipcRenderer.invoke('task:scan', taskId, dir),
  kanbanGenerate: () => ipcRenderer.invoke('kanban:generate'),
  // Auto-plan a task the first time it's opened without a checklist.
  ensurePlan: (id) => ipcRenderer.invoke('kanban:ensurePlan', id),
  // Project registry (built by discover-projects.ps1, no AI).
  projectsLoad: () => ipcRenderer.invoke('projects:load'),
  projectsRefresh: () => ipcRenderer.invoke('projects:refresh'),
  projectsOpen: (dir) => ipcRenderer.invoke('projects:open', dir),
  onProjectsUpdated: (cb) => ipcRenderer.on('projects:updated', () => cb()),
  // The AI's open questions and the user's answers to them.
  questionsLoad: () => ipcRenderer.invoke('questions:load'),
  questionsAnswer: (id, answer) => ipcRenderer.invoke('questions:answer', id, answer),
  // Settings + updates.
  settingsGet: () => ipcRenderer.invoke('settings:get'),
  settingsSet: (patch) => ipcRenderer.invoke('settings:set', patch),
  appInfo: () => ipcRenderer.invoke('app:info'),
  updateCheck: () => ipcRenderer.invoke('update:check'),
  updateState: () => ipcRenderer.invoke('update:state'),
  updateInstall: () => ipcRenderer.invoke('update:install'),
  onUpdateState: (cb) => ipcRenderer.on('update:state', (ev, state) => cb(state))
});
