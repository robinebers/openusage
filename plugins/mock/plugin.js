(function () {
  function lineText(opts) {
    var line = { type: "text", label: opts.label, value: opts.value }
    if (opts.color) line.color = opts.color
    if (opts.subtitle) line.subtitle = opts.subtitle
    return line
  }

  function lineProgress(opts) {
    var line = { type: "progress", label: opts.label, used: opts.used, limit: opts.limit, format: opts.format }
    if (opts.resetsAt) line.resetsAt = opts.resetsAt
    if (opts.periodDurationMs) line.periodDurationMs = opts.periodDurationMs
    if (opts.color) line.color = opts.color
    return line
  }

  function lineBadge(opts) {
    var line = { type: "badge", label: opts.label, text: opts.text }
    if (opts.color) line.color = opts.color
    if (opts.subtitle) line.subtitle = opts.subtitle
    return line
  }

  function probe() {
    var _15d = 15 * 24 * 60 * 60 * 1000
    var _30d = _15d * 2
    var _resets = new Date(Date.now() + _15d).toISOString()
    var _pastReset = new Date(Date.now() - 60000).toISOString()

    return {
      plan: "stress-test",
      lines: [
        // Pace statuses
        lineProgress({ label: "Ahead pace", used: 30, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        lineProgress({ label: "On Track pace", used: 45, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        lineProgress({ label: "Behind pace", used: 65, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        // Edge cases
        lineProgress({ label: "Empty bar", used: 0, limit: 500, format: { kind: "dollars" } }),
        lineProgress({ label: "Exactly full", used: 1000, limit: 1000, format: { kind: "count", suffix: "tokens" } }),
        lineProgress({ label: "Over limit!", used: 1337, limit: 1000, format: { kind: "count", suffix: "requests" } }),
        lineProgress({ label: "Huge numbers", used: 8429301, limit: 10000000, format: { kind: "count", suffix: "tokens" } }),
        lineProgress({ label: "Tiny sliver", used: 1, limit: 10000, format: { kind: "percent" } }),
        lineProgress({ label: "Almost full", used: 9999, limit: 10000, format: { kind: "percent" } }),
        lineProgress({ label: "Expired reset", used: 42, limit: 100, format: { kind: "percent" }, resetsAt: _pastReset, periodDurationMs: _30d }),
        // Text lines
        lineText({ label: "Status", value: "Active" }),
        lineText({ label: "Very long value", value: "This is an extremely long value string that should test text overflow and wrapping behavior in the card layout" }),
        lineText({ label: "", value: "Empty label" }),
        // Badge lines
        lineBadge({ label: "Tier", text: "Enterprise", color: "#8B5CF6" }),
        lineBadge({ label: "Alert", text: "Rate limited", color: "#ef4444" }),
        lineBadge({ label: "Region", text: "us-east-1" }),
      ],
    }
  }

  globalThis.__openusage_plugin = { id: "mock", probe }
})()
