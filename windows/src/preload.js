// The only bridge between the pages and the main process.
const { contextBridge, ipcRenderer } = require("electron");

const LISTEN = ["hook", "cursor", "prefs", "command", "drag-moved", "hooks-status", "card-state"];
const SEND = ["ready", "interactive", "drag-start", "show-menu", "settings-height",
  "card-submit", "card-close", "card-height", "card-copy"];
const INVOKE = ["drag-end", "get-state", "set-pref", "hooks-connect", "hooks-disconnect", "demo", "hotkey-recording"];

contextBridge.exposeInMainWorld("clawd", {
  on(channel, fn) {
    if (LISTEN.includes(channel)) ipcRenderer.on(channel, (_e, ...args) => fn(...args));
  },
  send(channel, ...args) {
    if (SEND.includes(channel)) ipcRenderer.send(channel, ...args);
  },
  invoke(channel, ...args) {
    return INVOKE.includes(channel) ? ipcRenderer.invoke(channel, ...args) : Promise.reject(new Error("blocked"));
  },
});
