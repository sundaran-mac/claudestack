// The bridge between the pages and the app. The reader page posts with csBridge.post (WebKit's
// messageHandlers on the Mac); the stack and the sidebar use `stack`.
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("csBridge", { post: (m) => ipcRenderer.send("page", m) });
contextBridge.exposeInMainWorld("stack", {
  send: (ch, m) => ipcRenderer.send("ui", ch, m),
  on: (cb) => ipcRenderer.on("ui", (_e, ch, m) => cb(ch, m)),
});
