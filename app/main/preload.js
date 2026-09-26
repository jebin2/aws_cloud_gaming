'use strict';
// The only bridge into the renderer: four calls and one event feed. No node, no
// filesystem, no AWS - and no way to run anything but cg.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('cg', {
  run: (args, env) => ipcRenderer.invoke('cg:run', { args, env }),
  answer: (id, text) => ipcRenderer.invoke('cg:answer', { id, text }),
  cancel: id => ipcRenderer.invoke('cg:cancel', id),
  busy: () => ipcRenderer.invoke('cg:busy'),
  onEvent: handler => {
    const listener = (_e, payload) => handler(payload);
    ipcRenderer.on('cg:event', listener);
    return () => ipcRenderer.removeListener('cg:event', listener);
  },
});
