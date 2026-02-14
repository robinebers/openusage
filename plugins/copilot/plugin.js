(function () {
  const KEYCHAIN_SERVICE = "OpenUsage-copilot";
  const GH_KEYCHAIN_SERVICE = "gh:github.com";
  const VAULT_KEY = "copilot:token";
  const USAGE_URL = "https://api.github.com/copilot_internal/user";

  function isKeychainAvailable(ctx) {
    if (!ctx.app) return false;
    return ctx.app.platform === "macos" || ctx.app.platform === "darwin";
  }

  function isVaultAvailable(ctx) {
    if (!ctx.app) return false;
    return ctx.app.platform === "windows";
  }

  function isWindows(ctx) {
    if (!ctx.app) return false;
    return ctx.app.platform === "windows";
  }

  function isLinux(ctx) {
    if (!ctx.app) return false;
    return ctx.app.platform === "linux";
  }

  function saveToken(ctx, token) {
    if (isVaultAvailable(ctx)) {
      try {
        ctx.host.vault.write(VAULT_KEY, JSON.stringify({ token: token }));
      } catch (e) {
        ctx.host.log.warn("vault write failed: " + String(e));
      }
      return;
    }
    if (isKeychainAvailable(ctx)) {
      try {
        ctx.host.keychain.writeGenericPassword(
          KEYCHAIN_SERVICE,
          JSON.stringify({ token: token }),
        );
      } catch (e) {
        ctx.host.log.warn("keychain write failed: " + String(e));
      }
    }
  }

  function clearCachedToken(ctx) {
    if (isVaultAvailable(ctx)) {
      try {
        ctx.host.vault.delete(VAULT_KEY);
      } catch (e) {
        ctx.host.log.info("vault delete failed: " + String(e));
      }
      return;
    }
    if (isKeychainAvailable(ctx)) {
      try {
        ctx.host.keychain.deleteGenericPassword(KEYCHAIN_SERVICE);
      } catch (e) {
        ctx.host.log.info("keychain delete failed: " + String(e));
      }
    }
  }

  function loadTokenFromKeychain(ctx) {
    if (!isKeychainAvailable(ctx)) return null;
    try {
      const raw = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE);
      if (raw) {
        const parsed = ctx.util.tryParseJson(raw);
        if (parsed && parsed.token) {
          ctx.host.log.info("token loaded from OpenUsage keychain");
          return { token: parsed.token, source: "keychain" };
        }
      }
    } catch (e) {
      ctx.host.log.info("OpenUsage keychain read failed: " + String(e));
    }
    return null;
  }

  function loadTokenFromVault(ctx) {
    if (!isVaultAvailable(ctx)) return null;
    try {
      const raw = ctx.host.vault.read(VAULT_KEY);
      if (raw) {
        const parsed = ctx.util.tryParseJson(raw);
        if (parsed && parsed.token) {
          ctx.host.log.info("token loaded from OpenUsage vault");
          return { token: parsed.token, source: "vault" };
        }
      }
    } catch (e) {
      ctx.host.log.info("OpenUsage vault read failed: " + String(e));
    }
    return null;
  }

  function loadTokenFromGhCli(ctx) {
    if (isKeychainAvailable(ctx)) {
      try {
        const raw = ctx.host.keychain.readGenericPassword(GH_KEYCHAIN_SERVICE);
        if (raw) {
          let token = raw;
          if (
            typeof token === "string" &&
            token.indexOf("go-keyring-base64:") === 0
          ) {
            token = ctx.base64.decode(token.slice("go-keyring-base64:".length));
          }
          if (token) {
            ctx.host.log.info("token loaded from gh CLI keychain");
            return { token: token, source: "gh-cli" };
          }
        }
      } catch (e) {
        ctx.host.log.info("gh CLI keychain read failed: " + String(e));
      }
      return null;
    }

    if (isWindows(ctx) || isLinux(ctx)) {
      const token = loadTokenFromGhCliFile(ctx);
      if (token) {
        ctx.host.log.info("token loaded from gh CLI config file");
        return { token: token, source: "gh-cli" };
      }
    }

    return null;
  }

  function loadTokenFromGhCliFile(ctx) {
    const paths = [
      "~/.config/gh/hosts.yml",
      "~/AppData/Roaming/GitHub CLI/hosts.yml",
      "~/AppData/Roaming/gh/hosts.yml",
    ];
    for (const path of paths) {
      try {
        if (!ctx.host.fs.exists(path)) continue;
        const text = ctx.host.fs.readText(path);
        const token = parseGhHostsToken(text, "github.com");
        if (token) return token;
      } catch (e) {
        ctx.host.log.warn("gh hosts file read failed: " + String(e));
      }
    }
    return null;
  }

  function parseGhHostsToken(text, host) {
    const lines = String(text || "").split(/\r?\n/);
    let currentHost = null;
    for (const line of lines) {
      const raw = String(line || "");
      const trimmed = raw.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;

      const isTopLevel = raw.length > 0 && raw[0] !== " " && raw[0] !== "\t";
      if (isTopLevel && trimmed.endsWith(":")) {
        let key = trimmed.slice(0, -1).trim();
        if ((key.startsWith("\"") && key.endsWith("\"")) || (key.startsWith("'") && key.endsWith("'"))) {
          key = key.slice(1, -1);
        }
        currentHost = key || null;
        continue;
      }

      if (currentHost === host && trimmed.startsWith("oauth_token:")) {
        let value = trimmed.slice("oauth_token:".length).trim();
        if (!value) return null;
        if ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1);
        }
        return value || null;
      }
    }
    return null;
  }

  function loadToken(ctx) {
    return (
      loadTokenFromVault(ctx) ||
      loadTokenFromKeychain(ctx) ||
      loadTokenFromGhCli(ctx)
    );
  }

  function fetchUsage(ctx, token) {
    return ctx.util.request({
      method: "GET",
      url: USAGE_URL,
      headers: {
        Authorization: "token " + token,
        Accept: "application/json",
        "Editor-Version": "vscode/1.96.2",
        "Editor-Plugin-Version": "copilot-chat/0.26.7",
        "User-Agent": "GitHubCopilotChat/0.26.7",
        "X-Github-Api-Version": "2025-04-01",
      },
      timeoutMs: 10000,
    });
  }

  function makeProgressLine(ctx, label, snapshot, resetDate) {
    if (!snapshot || typeof snapshot.percent_remaining !== "number")
      return null;
    const usedPercent = Math.min(100, Math.max(0, 100 - snapshot.percent_remaining));
    return ctx.line.progress({
      label: label,
      used: usedPercent,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: ctx.util.toIso(resetDate),
      periodDurationMs: 30 * 24 * 60 * 60 * 1000,
    });
  }

  function makeLimitedProgressLine(ctx, label, remaining, total, resetDate) {
    if (typeof remaining !== "number" || typeof total !== "number" || total <= 0)
      return null;
    const used = total - remaining;
    const usedPercent = Math.min(100, Math.max(0, Math.round((used / total) * 100)));
    return ctx.line.progress({
      label: label,
      used: usedPercent,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: ctx.util.toIso(resetDate),
      periodDurationMs: 30 * 24 * 60 * 60 * 1000,
    });
  }

  function probe(ctx) {
    const cred = loadToken(ctx);
    if (!cred) {
      throw "Not logged in. Run `gh auth login` first.";
    }

    let token = cred.token;
    let source = cred.source;

    let resp;
    try {
      resp = fetchUsage(ctx, token);
    } catch (e) {
      ctx.host.log.error("usage request exception: " + String(e));
      throw "Usage request failed. Check your connection.";
    }

    if (resp.status === 401 || resp.status === 403) {
      // If cached token is stale, clear it and try fallback sources
      if (source === "keychain") {
        ctx.host.log.info("cached token invalid, trying fallback sources");
        clearCachedToken(ctx);
        const fallback = loadTokenFromGhCli(ctx);
        if (fallback) {
          try {
            resp = fetchUsage(ctx, fallback.token);
          } catch (e) {
            ctx.host.log.error("fallback usage request exception: " + String(e));
            throw "Usage request failed. Check your connection.";
          }
          if (resp.status >= 200 && resp.status < 300) {
            // Fallback worked, persist the new token
            saveToken(ctx, fallback.token);
            token = fallback.token;
            source = fallback.source;
          }
        }
      }
      // Still failing after retry
      if (resp.status === 401 || resp.status === 403) {
        throw "Token invalid. Run `gh auth login` to re-authenticate.";
      }
    }

    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.error("usage returned error: status=" + resp.status);
      throw (
        "Usage request failed (HTTP " +
        String(resp.status) +
        "). Try again later."
      );
    }

    // Persist gh-cli token to OpenUsage keychain for future use
    if (source === "gh-cli") {
      saveToken(ctx, token);
    }

    const data = ctx.util.tryParseJson(resp.bodyText);
    if (data === null) {
      throw "Usage response invalid. Try again later.";
    }

    ctx.host.log.info("usage fetch succeeded");

    const lines = [];
    let plan = null;
    if (data.copilot_plan) {
      plan = ctx.fmt.planLabel(data.copilot_plan);
    }

    // Paid tier: quota_snapshots
    const snapshots = data.quota_snapshots;
    if (snapshots) {
      const premiumLine = makeProgressLine(
        ctx,
        "Premium",
        snapshots.premium_interactions,
        data.quota_reset_date,
      );
      if (premiumLine) lines.push(premiumLine);

      const chatLine = makeProgressLine(
        ctx,
        "Chat",
        snapshots.chat,
        data.quota_reset_date,
      );
      if (chatLine) lines.push(chatLine);
    }

    // Free tier: limited_user_quotas
    if (data.limited_user_quotas && data.monthly_quotas) {
      const lq = data.limited_user_quotas;
      const mq = data.monthly_quotas;
      const resetDate = data.limited_user_reset_date;

      const chatLine = makeLimitedProgressLine(ctx, "Chat", lq.chat, mq.chat, resetDate);
      if (chatLine) lines.push(chatLine);

      const completionsLine = makeLimitedProgressLine(ctx, "Completions", lq.completions, mq.completions, resetDate);
      if (completionsLine) lines.push(completionsLine);
    }

    if (lines.length === 0) {
      lines.push(
        ctx.line.badge({
          label: "Status",
          text: "No usage data",
          color: "#a3a3a3",
        }),
      );
    }

    return { plan: plan, lines: lines };
  }

  globalThis.__openusage_plugin = { id: "copilot", probe };
})();
