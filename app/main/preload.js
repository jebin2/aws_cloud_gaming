'use strict';
// The only bridge into the renderer: five calls and one event feed. No node, no
// filesystem, no AWS - and no way to run anything but cg.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('cg', {
  run: (args, env) => ipcRenderer.invoke('cg:run', { args, env }),
  answer: (id, text) => ipcRenderer.invoke('cg:answer', { id, text }),
  cancel: id => ipcRenderer.invoke('cg:cancel', id),
  busy: () => ipcRenderer.invoke('cg:busy'),
  asks: () => ipcRenderer.invoke('cg:asks'),
  // The only web addresses this app may open. Tailscale's sign-in finishes in a
  // browser and there is no way around that; everything else stays denied.
  // The main process checks the URL again - a renderer is not trusted to.
  openSignIn: url => ipcRenderer.invoke('cg:open-signin', url),
  onEvent: handler => {
    const listener = (_e, payload) => handler(payload);
    ipcRenderer.on('cg:event', listener);
    return () => ipcRenderer.removeListener('cg:event', listener);
  },
});
