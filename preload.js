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
  aiKill: () => ipcRenderer.invoke('ai:kill'),
  aiOpenContext: () => ipcRenderer.invoke('ai:openContext'),
  scanFolder: (taskId, dir) => ipcRenderer.invoke('task:scan', taskId, dir)
});
