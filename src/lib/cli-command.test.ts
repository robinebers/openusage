import { describe, expect, it, vi, beforeEach } from "vitest";
import {
  getCliCommandStatus,
  installCliCommand,
  uninstallCliCommand,
  type CliCommandStatus,
} from "@/lib/cli-command";

const state = vi.hoisted(() => ({
  invokeMock: vi.fn(),
}));

vi.mock("@tauri-apps/api/core", () => ({
  invoke: state.invokeMock,
}));

const sampleStatus: CliCommandStatus = {
  installed: true,
  installPath: "/Users/test/.local/bin/openusage-cli",
  pluginsDir: "/Users/test/Library/Application Support/com.sunstory.openusage/plugins",
  pathExport: "export PATH=\"$HOME/.local/bin:$PATH\"",
  pluginsExport:
    "export OPENUSAGE_PLUGINS_DIR=\"/Users/test/Library/Application Support/com.sunstory.openusage/plugins\"",
};

describe("cli-command", () => {
  beforeEach(() => {
    state.invokeMock.mockReset();
    state.invokeMock.mockResolvedValue(sampleStatus);
  });

  it("gets cli command status", async () => {
    await expect(getCliCommandStatus()).resolves.toEqual(sampleStatus);
    expect(state.invokeMock).toHaveBeenCalledWith("cli_command_status");
  });

  it("installs cli command", async () => {
    await expect(installCliCommand()).resolves.toEqual(sampleStatus);
    expect(state.invokeMock).toHaveBeenCalledWith("install_cli_command");
  });

  it("uninstalls cli command", async () => {
    await expect(uninstallCliCommand()).resolves.toEqual(sampleStatus);
    expect(state.invokeMock).toHaveBeenCalledWith("uninstall_cli_command");
  });
});
