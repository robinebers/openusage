(function () {
  const KEYCHAIN_SERVICE = "OpenUsage-copilot";
  const GH_KEYCHAIN_SERVICE = "gh:github.com";
  const USAGE_URL = "https://api.github.com/copilot_internal/user";

  function readJson(ctx, path) {
    try {
      if (!ctx.host.fs.exists(path)) return null;
      const text = ctx.host.fs.readText(path);
      return ctx.util.tryParseJson(text);
    } catch (e) {
      ctx.host.log.warn("readJson failed for " + path + ": " + String(e));
      return null;
    }
  }

  function writeJson(ctx, path, value) {
    try {
      ctx.host.fs.writeText(path, JSON.stringify(value));
    } catch (e) {
      ctx.host.log.warn("writeJson failed for " + path + ": " + String(e));
    }
  }

  function readEnv(ctx, key) {
    try {
      if (!ctx.host.env || typeof ctx.host.env.get !== "function") return null;
      const value = ctx.host.env.get(key);
      if (value === null || value === undefined) return null;
      const text = String(value).trim();
      return text || null;
    } catch (e) {
      ctx.host.log.info("env read failed for " + key + ": " + String(e));
      return null;
    }
  }

  function unquoteYamlScalar(value) {
    if (typeof value !== "string") return null;
    let text = value.trim();
    if (!text) return null;
    const commentStart = text.indexOf(" #");
    if (commentStart >= 0) text = text.slice(0, commentStart).trim();
    if (
      (text.startsWith('"') && text.endsWith('"')) ||
      (text.startsWith("'") && text.endsWith("'"))
    ) {
      text = text.slice(1, -1);
    }
    return text || null;
  }

  function parseGhHostsToken(text) {
    if (typeof text !== "string" || !text) return null;
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const hostMatch = lines[i].match(/^([^\s#][^:]*)\s*:\s*(?:#.*)?$/);
      if (!hostMatch) continue;
      const host = unquoteYamlScalar(hostMatch[1]);
      if (host !== "github.com") continue;

      for (let j = i + 1; j < lines.length; j++) {
        const line = lines[j];
        if (/^[^\s#][^:]*\s*:/.test(line)) break;
        const tokenMatch = line.match(/^\s+oauth_token\s*:\s*(.+)\s*$/);
        if (!tokenMatch) continue;
        const token = unquoteYamlScalar(tokenMatch[1]);
        if (token) return token;
      }
    }
    return null;
  }

  function buildGhHostsPaths(ctx) {
    const paths = [];
    const ghConfigDir = readEnv(ctx, "GH_CONFIG_DIR");
    const xdgConfigHome = readEnv(ctx, "XDG_CONFIG_HOME");
    const home = readEnv(ctx, "HOME");

    if (ghConfigDir) paths.push(ghConfigDir + "/hosts.yml");
    if (xdgConfigHome) paths.push(xdgConfigHome + "/gh/hosts.yml");
    if (home) paths.push(home + "/.config/gh/hosts.yml");

    const unique = [];
    for (const path of paths) {
      if (unique.indexOf(path) === -1) unique.push(path);
    }
    return unique;
  }

  function saveToken(ctx, token) {
    try {
      ctx.host.keychain.writeGenericPassword(
        KEYCHAIN_SERVICE,
        JSON.stringify({ token: token }),
      );
    } catch (e) {
      ctx.host.log.warn("keychain write failed: " + String(e));
    }
    writeJson(ctx, ctx.app.pluginDataDir + "/auth.json", { token: token });
  }

  function clearCachedToken(ctx) {
    try {
      ctx.host.keychain.deleteGenericPassword(KEYCHAIN_SERVICE);
    } catch (e) {
      ctx.host.log.info("keychain delete failed: " + String(e));
    }
    writeJson(ctx, ctx.app.pluginDataDir + "/auth.json", null);
  }

  function loadTokenFromKeychain(ctx) {
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

  function loadTokenFromGhCli(ctx) {
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

  function loadTokenFromGhHostsFile(ctx) {
    const paths = buildGhHostsPaths(ctx);
    for (const path of paths) {
      try {
        if (!ctx.host.fs.exists(path)) continue;
        const text = ctx.host.fs.readText(path);
        const token = parseGhHostsToken(text);
        if (token) {
          ctx.host.log.info("token loaded from gh hosts file: " + path);
          return { token: token, source: "gh-hosts-file" };
        }
        ctx.host.log.info(
          "gh hosts file has no oauth_token for github.com: " + path,
        );
      } catch (e) {
        ctx.host.log.info("gh hosts file read failed for " + path + ": " + String(e));
      }
    }
    return null;
  }

  function loadTokenFromGhCliCommand(ctx) {
    try {
      if (
        !ctx.host.keychain ||
        typeof ctx.host.keychain.readGhCliToken !== "function"
      ) {
        return null;
      }
      const token = ctx.host.keychain.readGhCliToken();
      if (token) {
        ctx.host.log.info("token loaded from gh CLI command");
        return { token: token, source: "gh-cli-command" };
      }
    } catch (e) {
      ctx.host.log.info("gh CLI command read failed: " + String(e));
    }
    return null;
  }

  function loadTokenFromGhSources(ctx) {
    return (
      loadTokenFromGhCli(ctx) ||
      loadTokenFromGhHostsFile(ctx) ||
      loadTokenFromGhCliCommand(ctx)
    );
  }

  function loadTokenFromStateFile(ctx) {
    const data = readJson(ctx, ctx.app.pluginDataDir + "/auth.json");
    if (data && data.token) {
      ctx.host.log.info("token loaded from state file");
      return { token: data.token, source: "state" };
    }
    return null;
  }

  function loadToken(ctx) {
    return (
      loadTokenFromKeychain(ctx) ||
      loadTokenFromGhSources(ctx) ||
      loadTokenFromStateFile(ctx)
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
        const fallback = loadTokenFromGhSources(ctx);
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

    // Persist gh-provided token to OpenUsage keychain for future use
    if (
      source === "gh-cli" ||
      source === "gh-hosts-file" ||
      source === "gh-cli-command"
    ) {
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
