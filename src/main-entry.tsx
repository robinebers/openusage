import React from "react";
import ReactDOM from "react-dom/client";
import { error as logError, warn as logWarn } from "@tauri-apps/plugin-log";
import { App } from "./App";

type ConsoleForwardingState = {
  installed: boolean;
  originalError: (...args: unknown[]) => void;
  originalWarn: (...args: unknown[]) => void;
};

type ConsoleWithForwardingState = Console & {
  __openUsageLogForwarding?: ConsoleForwardingState;
};

function getConsoleForwardingState(): ConsoleForwardingState {
  const consoleWithState = console as ConsoleWithForwardingState;
  if (!consoleWithState.__openUsageLogForwarding) {
    consoleWithState.__openUsageLogForwarding = {
      installed: false,
      originalError: console.error.bind(console),
      originalWarn: console.warn.bind(console),
    };
  }
  return consoleWithState.__openUsageLogForwarding;
}

function stringify(arg: unknown): string {
  if (arg === null) return "null";
  if (arg === undefined) return "undefined";
  if (typeof arg === "string") return arg;
  if (arg instanceof Error) return `${arg.name}: ${arg.message}`;
  try {
    return JSON.stringify(arg);
  } catch {
    return String(arg);
  }
}

export function installConsoleLogForwarding() {
  const forwardingState = getConsoleForwardingState();
  if (forwardingState.installed) return;
  forwardingState.installed = true;

  console.error = (...args: unknown[]) => {
    forwardingState.originalError(...args);
    logError(args.map(stringify).join(" ")).catch(() => {});
  };

  console.warn = (...args: unknown[]) => {
    forwardingState.originalWarn(...args);
    logWarn(args.map(stringify).join(" ")).catch(() => {});
  };
}

export function mountApp() {
  installConsoleLogForwarding();
  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}
