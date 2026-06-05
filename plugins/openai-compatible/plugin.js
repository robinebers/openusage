(function () {
  var LEDGER_FILE = "openai-compatible-usage.json";

  function readLedger(ctx) {
    var path = ctx.app.appDataDir.replace(/\/+$/, "") + "/" + LEDGER_FILE;
    if (!ctx.host.fs.exists(path)) return [];

    var parsed = ctx.util.tryParseJson(ctx.host.fs.readText(path));
    if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.entries)) {
      return [];
    }
    return parsed.entries;
  }

  function dayPrefix(iso) {
    return String(iso || "").slice(0, 10);
  }

  function monthPrefix(iso) {
    return String(iso || "").slice(0, 7);
  }

  function add(bucket, entry) {
    bucket.inputTokens += Number(entry.inputTokens || 0);
    bucket.outputTokens += Number(entry.outputTokens || 0);
    bucket.costUsd += Number(entry.costUsd || 0);
    if (entry.unmetered) bucket.unmeteredRequests += 1;
  }

  function summarize(entries, nowIso) {
    var today = dayPrefix(nowIso);
    var month = monthPrefix(nowIso);
    var summary = {
      today: emptyBucket(),
      month: emptyBucket(),
      total: emptyBucket(),
      unpricedModels: {},
      dailyCosts: {},
    };

    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i] || {};
      var fetchedAt = String(entry.fetchedAt || entry.fetched_at || "");
      add(summary.total, entry);
      if (fetchedAt.indexOf(today) === 0) add(summary.today, entry);
      if (fetchedAt.indexOf(month) === 0) add(summary.month, entry);
      if (entry.unpriced && entry.model) summary.unpricedModels[String(entry.model)] = true;
      if (typeof entry.costUsd === "number" && fetchedAt.length >= 10) {
        var day = fetchedAt.slice(0, 10);
        summary.dailyCosts[day] = (summary.dailyCosts[day] || 0) + entry.costUsd;
      }
    }

    return summary;
  }

  function emptyBucket() {
    return {
      inputTokens: 0,
      outputTokens: 0,
      costUsd: 0,
      unmeteredRequests: 0,
    };
  }

  function formatMoney(value) {
    if (!Number.isFinite(value)) return "$0.0000";
    return "$" + value.toFixed(value < 0.01 ? 4 : 2);
  }

  function formatTokens(value) {
    if (value >= 1000000) {
      return trimFixed(value / 1000000, 1) + "M tokens";
    }
    if (value >= 1000) {
      return trimFixed(value / 1000, 1) + "K tokens";
    }
    return String(value) + " tokens";
  }

  function trimFixed(value, digits) {
    return value.toFixed(digits).replace(/\.0$/, "");
  }

  function bucketText(bucket) {
    return formatMoney(bucket.costUsd) + " · " + formatTokens(bucket.inputTokens + bucket.outputTokens);
  }

  function dailySpendPoints(dailyCosts) {
    var days = Object.keys(dailyCosts).sort().slice(-14);
    return days.map(function (day) {
      return {
        label: day.slice(5),
        value: dailyCosts[day],
        valueLabel: formatMoney(dailyCosts[day]),
      };
    });
  }

  function pluralRequest(count) {
    return count === 1 ? "1 request" : String(count) + " requests";
  }

  function probe(ctx) {
    var entries = readLedger(ctx);
    if (entries.length === 0) {
      return {
        providerId: "openai-compatible",
        displayName: "OpenAI Compatible API",
        plan: "Local proxy",
        lines: [
          ctx.line.badge({
            label: "Setup",
            text: "Proxy not used yet",
          }),
        ],
      };
    }

    var summary = summarize(entries, ctx.nowIso);
    var lines = [
      ctx.line.text({ label: "Today", value: bucketText(summary.today) }),
      ctx.line.text({ label: "This Month", value: bucketText(summary.month) }),
      ctx.line.text({ label: "Total", value: bucketText(summary.total) }),
    ];

    var unpriced = Object.keys(summary.unpricedModels).sort();
    if (unpriced.length > 0) {
      lines.push(ctx.line.badge({
        label: "Unpriced Models",
        text: unpriced.join(", "),
        color: "#f59e0b",
      }));
    }
    if (summary.total.unmeteredRequests > 0) {
      lines.push(ctx.line.badge({
        label: "Unmetered",
        text: pluralRequest(summary.total.unmeteredRequests),
        color: "#f59e0b",
      }));
    }

    var points = dailySpendPoints(summary.dailyCosts);
    if (points.length > 0) {
      lines.push(ctx.line.barChart({
        label: "Daily Spend",
        points: points,
        note: "From local proxy metering",
      }));
    }

    return {
      providerId: "openai-compatible",
      displayName: "OpenAI Compatible API",
      plan: "Local proxy",
      lines: lines,
    };
  }

  globalThis.__openusage_plugin = {
    id: "openai-compatible",
    probe: probe,
  };
})();
