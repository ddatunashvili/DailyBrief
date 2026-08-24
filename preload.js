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
  // Failed / incomplete / late AI runs: the journal, the live event, and the
  // one text file to send on when something needs fixing.
  aiProblems: () => ipcRenderer.invoke('ai:problems'),
  onAiProblem: (cb) => ipcRenderer.on('ai:problem', (ev, p) => cb(p)),
  aiOpenDiagnostics: () => ipcRenderer.invoke('ai:openDiagnostics'),
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
  // Execute: AI does the task in the real project, on its own git branch.
  taskExecute: (id) => ipcRenderer.invoke('task:execute', id),
  // Ask page: free-text questions about the project registry.
  askLoad: () => ipcRenderer.invoke('ask:load'),
  askSend: (text, dir) => ipcRenderer.invoke('ask:send', text, dir),
  askClear: () => ipcRenderer.invoke('ask:clear'),
  onAskUpdated: (cb) => ipcRenderer.on('ask:updated', () => cb()),
  // Per-project feature suggestions (3 at a time, accept or decline).
  ideasLoad: () => ipcRenderer.invoke('ideas:load'),
  ideasGenerate: (dir) => ipcRenderer.invoke('ideas:generate', dir),
  ideasDecide: (dir, ideaId, state, taskId) => ipcRenderer.invoke('ideas:decide', dir, ideaId, state, taskId),
  onIdeasUpdated: (cb) => ipcRenderer.on('ideas:updated', () => cb()),
  // Ignored folders: excluded from the monitor, the registry and every digest.
  ignoreLoad: () => ipcRenderer.invoke('ignore:load'),
  ignoreAdd: (dir) => ipcRenderer.invoke('ignore:add', dir),
  ignoreRemove: (dir) => ipcRenderer.invoke('ignore:remove', dir),
  ignoreSearch: (query) => ipcRenderer.invoke('ignore:search', query),
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
