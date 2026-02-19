import { invoke } from "@tauri-apps/api/core";

export type CliCommandStatus = {
  installed: boolean;
  installPath: string;
  pluginsDir: string;
  pathExport: string;
  pluginsExport: string;
};

const CLI_STATUS_CMD = "cli_command_status";
const CLI_INSTALL_CMD = "install_cli_command";
const CLI_UNINSTALL_CMD = "uninstall_cli_command";

export async function getCliCommandStatus(): Promise<CliCommandStatus> {
  return invoke<CliCommandStatus>(CLI_STATUS_CMD);
}

export async function installCliCommand(): Promise<CliCommandStatus> {
  return invoke<CliCommandStatus>(CLI_INSTALL_CMD);
}

export async function uninstallCliCommand(): Promise<CliCommandStatus> {
  return invoke<CliCommandStatus>(CLI_UNINSTALL_CMD);
}
