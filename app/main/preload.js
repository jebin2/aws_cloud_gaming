'use strict';
// The only bridge into the renderer: six calls and one event feed. No node, no
// filesystem, no AWS - and no way to run anything but ayis.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ayis', {
  run: (args, env) => ipcRenderer.invoke('ayis:run', { args, env }),
  answer: (id, text) => ipcRenderer.invoke('ayis:answer', { id, text }),
  cancel: id => ipcRenderer.invoke('ayis:cancel', id),
  busy: () => ipcRenderer.invoke('ayis:busy'),
  asks: () => ipcRenderer.invoke('ayis:asks'),
  engine: () => ipcRenderer.invoke('ayis:engine'),
  // The folder of run logs, opened in the file manager; it answers where it is.
  openLogs: () => ipcRenderer.invoke('ayis:open-logs'),
  // The only web addresses this app may open. Tailscale's sign-in finishes in a
  // browser and there is no way around that; everything else stays denied.
  // The main process checks the URL again - a renderer is not trusted to.
  openSignIn: url => ipcRenderer.invoke('ayis:open-signin', url),
  onEvent: handler => {
    const listener = (_e, payload) => handler(payload);
    ipcRenderer.on('ayis:event', listener);
    return () => ipcRenderer.removeListener('ayis:event', listener);
  },
});
