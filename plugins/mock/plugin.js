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
    var _10m = 10 * 60 * 1000
    var _6h = 6 * 60 * 60 * 1000
    var _12h = 12 * 60 * 60 * 1000
    var _24h = 24 * 60 * 60 * 1000
    var _2d3h = (2 * 24 + 3) * 60 * 60 * 1000
    var _8d = 8 * 24 * 60 * 60 * 1000
    var _15d = 15 * 24 * 60 * 60 * 1000
    var _30d = _15d * 2
    var _soonReset = new Date(Date.now() + _10m).toISOString()
    var _hourReset = new Date(Date.now() + _6h).toISOString()
    var _halfDayReset = new Date(Date.now() + _12h).toISOString()
    var _multiDayReset = new Date(Date.now() + _2d3h).toISOString()
    var _weekReset = new Date(Date.now() + _8d).toISOString()
    var _resets = new Date(Date.now() + _15d).toISOString()
    var _pastReset = new Date(Date.now() - 60000).toISOString()

    return {
      plan: "stress-test",
      lines: [
        // Pace statuses
        lineProgress({ label: "Ahead pace", used: 30, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        lineProgress({ label: "On Track pace", used: 45, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        lineProgress({ label: "Behind pace", used: 65, limit: 100, format: { kind: "percent" }, resetsAt: _resets, periodDurationMs: _30d }),
        // Marker demo: in default "used" mode, time marker sits on the empty side
        lineProgress({ label: "Time marker empty-side demo", used: 20, limit: 100, format: { kind: "percent" }, resetsAt: _halfDayReset, periodDurationMs: _24h }),
        // Edge cases
        lineProgress({ label: "Empty bar", used: 0, limit: 500, format: { kind: "dollars" } }),
        lineProgress({ label: "Exactly full", used: 1000, limit: 1000, format: { kind: "count", suffix: "tokens" } }),
        lineProgress({ label: "Over limit!", used: 1337, limit: 1000, format: { kind: "count", suffix: "requests" } }),
        lineProgress({ label: "Huge numbers", used: 8429301, limit: 10000000, format: { kind: "count", suffix: "tokens" } }),
        lineProgress({ label: "Tiny sliver", used: 1, limit: 10000, format: { kind: "percent" } }),
        lineProgress({ label: "Almost full", used: 9999, limit: 10000, format: { kind: "percent" } }),
        lineProgress({ label: "Reset in minutes", used: 12, limit: 100, format: { kind: "percent" }, resetsAt: _soonReset }),
        lineProgress({ label: "Reset in hours", used: 28, limit: 100, format: { kind: "percent" }, resetsAt: _hourReset }),
        lineProgress({ label: "Reset in days", used: 43, limit: 100, format: { kind: "percent" }, resetsAt: _multiDayReset }),
        lineProgress({ label: "Reset in week+", used: 56, limit: 100, format: { kind: "percent" }, resetsAt: _weekReset }),
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
