import React from "react";
import ReactDOM from "react-dom/client";
import { error as logError, warn as logWarn } from "@tauri-apps/plugin-log";
import App from "./App";
import "./index.css";

// Forward console.error and console.warn to Tauri log file
const originalError = console.error;
console.error = (...args: unknown[]) => {
  originalError(...args);
  logError(args.map(String).join(" ")).catch(() => {});
};

const originalWarn = console.warn;
console.warn = (...args: unknown[]) => {
  originalWarn(...args);
  logWarn(args.map(String).join(" ")).catch(() => {});
};

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
