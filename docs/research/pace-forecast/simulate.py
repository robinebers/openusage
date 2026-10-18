#!/usr/bin/env python3
"""Walk-forward pace-forecast simulation on OpenUsage log-scan-cache.

Does not touch the app. Compares:
  linear            current OpenUsage: used/elapsed * period
  seasonal_naive    median remaining at the same slot over last K completed cycles
  shape_index       used / typical_share_elapsed (weekday/hour or session elapsed)
  tu_blend          tokenusage-style blend of window / today / 30d rates

Quantity: work tokens = input + output + cacheWrite5m + cacheWrite1h
(cacheRead excluded — it dominates Claude totals and is not quota-like).

Windows:
  weekly  ISO week Mon 00:00 local
  session Anthropic-style 5h block from first event; next event after end starts a new one
"""

from __future__ import annotations

import glob
import os
import statistics
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterable
from zoneinfo import ZoneInfo

import plistlib

TZ = ZoneInfo("Asia/Singapore")
CACHE = os.path.expanduser("~/Library/Application Support/OpenUsage/log-scan-cache")
K_HISTORY = 3
SESSION_HOURS = 5
WEEK_HOURS = 7 * 24
MIN_ELAPSED_FRAC = 0.01
SYNTH_LIMIT_Q = 0.80
NS_SPECS = {
    "claude": "claude-eded6b9a919b4c64",
    "grok": "grok-c4aa7b2d6a0e488f",
}


def work_tokens(tok: dict | None) -> int:
    if not tok:
        return 0
    return int(tok.get("input") or 0) + int(tok.get("output") or 0) + int(
        tok.get("cacheWrite5m") or 0
    ) + int(tok.get("cacheWrite1h") or 0)


def total_tokens(tok: dict | None) -> int:
    if not tok:
        return 0
    return work_tokens(tok) + int(tok.get("cacheRead") or 0)


def as_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def to_local(dt: datetime) -> datetime:
    return as_utc(dt).astimezone(TZ)


def monday_start(local_dt: datetime) -> datetime:
    midnight = local_dt.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight - timedelta(days=midnight.weekday())


def median(xs: list[float]) -> float:
    return float(statistics.median(xs)) if xs else 0.0


def quantile(xs: list[float], q: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return float(s[i])


def mape(errs: list[tuple[float, float]]) -> float:
    """errs: (predicted, actual) with actual>0."""
    vals = [abs(p - a) / a for p, a in errs if a > 0]
    return 100.0 * (sum(vals) / len(vals)) if vals else float("nan")


def mae_frac(errs: list[tuple[float, float]]) -> float:
    vals = [abs(p - a) for p, a in errs]
    return (sum(vals) / len(vals)) if vals else float("nan")


@dataclass
class Event:
    ts: datetime  # UTC
    local: datetime
    work: int
    total: int
    source: str
    dedup: str


def load_plist(path: str) -> list[tuple]:
    with open(path, "rb") as f:
        rec = plistlib.load(f)
    items = rec.get("items") or []
    src = rec.get("path") or path
    out = []
    for it in items:
        ts = it.get("timestamp")
        if not isinstance(ts, datetime):
            continue
        tok = it.get("tokens") if isinstance(it.get("tokens"), dict) else None
        if tok is None and any(k in it for k in ("input", "output")):
            tok = it
        wt = work_tokens(tok)
        tt = total_tokens(tok)
        if wt <= 0 and tt <= 0:
            continue
        did = it.get("messageID") or it.get("eventID") or it.get("id") or ""
        req = it.get("requestID") or ""
        dedup = f"{did}|{req}" if did else f"{src}|{ts.isoformat()}"
        out.append((ts, wt, tt, dedup))
    return out


def load_namespace(ns_dir: str, source: str) -> list[Event]:
    files = glob.glob(os.path.join(CACHE, ns_dir, "files", "*.plist"))
    events: list[Event] = []
    seen: set[str] = set()
    t0 = time.perf_counter()
    # IO-bound plist reads; threads beat processes here (no pickle of items).
    with ThreadPoolExecutor(max_workers=8) as pool:
        for batch in pool.map(load_plist, files, chunksize=32):
            for ts, wt, tt, dedup in batch:
                if dedup in seen:
                    continue
                seen.add(dedup)
                utc = as_utc(ts)
                events.append(
                    Event(ts=utc, local=utc.astimezone(TZ), work=wt, total=tt, source=source, dedup=dedup)
                )
    events.sort(key=lambda e: e.ts)
    print(
        f"  loaded {source}: {len(files)} files, {len(events)} events "
        f"in {time.perf_counter()-t0:.2f}s"
    )
    return events


@dataclass
class Window:
    start: datetime  # local
    end: datetime
    kind: str  # weekly | session
    # parallel arrays
    ts: list[datetime] = field(default_factory=list)  # local
    cum: list[float] = field(default_factory=list)
    elapsed_s: list[float] = field(default_factory=list)
    slot: list[int] = field(default_factory=list)
    start_hour: int = 0
    total: float = 0.0
    n_events: int = 0


def build_weekly(events: list[Event]) -> list[Window]:
    buckets: dict[datetime, list[Event]] = defaultdict(list)
    for e in events:
        buckets[monday_start(e.local)].append(e)
    windows: list[Window] = []
    for start in sorted(buckets):
        end = start + timedelta(days=7)
        w = Window(start=start, end=end, kind="weekly", start_hour=start.hour)
        cum = 0.0
        last_hour_slot = -1
        # hourly samples: last cum of each hour that had activity, plus hour-end
        hour_cum: dict[int, float] = {}
        n = 0
        for e in buckets[start]:
            cum += e.work
            n += 1
            slot = int((e.local - start).total_seconds() // 3600)
            slot = min(max(slot, 0), WEEK_HOURS - 1)
            hour_cum[slot] = cum
        running = 0.0
        for slot in range(WEEK_HOURS):
            if slot in hour_cum:
                running = hour_cum[slot]
            # sample every hour; skip empty leading hours (no usage yet)
            if running <= 0:
                continue
            t = start + timedelta(hours=slot, minutes=59)
            elapsed = (t - start).total_seconds()
            w.ts.append(t)
            w.cum.append(running)
            w.elapsed_s.append(elapsed)
            w.slot.append(slot)
        w.total = cum
        w.n_events = n
        if w.total > 0 and w.ts:
            windows.append(w)
    return windows


def build_sessions(events: list[Event]) -> list[Window]:
    windows: list[Window] = []
    block: Window | None = None
    period = timedelta(hours=SESSION_HOURS)
    bucket_s = 10 * 60

    def close(w: Window) -> None:
        if w.total > 0 and w.ts:
            windows.append(w)

    for e in events:
        if block is None or e.local >= block.end:
            if block is not None:
                close(block)
            start = e.local
            block = Window(
                start=start,
                end=start + period,
                kind="session",
                start_hour=start.hour,
            )
        block.n_events += 1
        block.total += e.work
        elapsed = (e.local - block.start).total_seconds()
        slot = int(elapsed // bucket_s)
        # keep last sample per 10-min bucket
        if block.slot and block.slot[-1] == slot:
            block.cum[-1] = block.total
            block.ts[-1] = e.local
            block.elapsed_s[-1] = elapsed
        else:
            block.ts.append(e.local)
            block.cum.append(block.total)
            block.elapsed_s.append(elapsed)
            block.slot.append(slot)
    if block is not None:
        close(block)
    return windows


def eval_points(w: Window, period_s: float) -> list[int]:
    """Indices into w arrays that are valid pace-eval points."""
    out = []
    min_elapsed = max(60.0, period_s * MIN_ELAPSED_FRAC)
    for i, elapsed in enumerate(w.elapsed_s):
        remaining = period_s - elapsed
        if elapsed < min_elapsed or remaining < 60:
            continue
        if w.cum[i] <= 0:
            continue
        out.append(i)
    return out


@dataclass
class Forecasts:
    linear: float
    seasonal: float
    shape: float
    tu_blend: float
    used: float
    actual: float
    elapsed_frac: float
    weekday: int
    hour: int
    start_hour: int
    kind: str
    fallback_seasonal: bool
    fallback_shape: bool


def predict_window(
    w: Window,
    i: int,
    period_s: float,
    history: list[Window],
    daily_rate: float,
    kind: str,
) -> Forecasts:
    used = w.cum[i]
    elapsed = w.elapsed_s[i]
    elapsed_frac = elapsed / period_s
    remaining_s = period_s - elapsed
    actual = w.total
    slot = w.slot[i]
    wd = w.ts[i].weekday()
    hour = w.ts[i].hour

    linear = used / elapsed_frac if elapsed_frac > 0 else used

    # --- seasonal naive: median remaining at same slot ---
    remainders: list[float] = []
    shares: list[float] = []
    # most recent completed cycles first
    for hw in reversed(history):
        if kind == "session" and hw.start_hour != w.start_hour:
            continue
        # find last sample at slot <= current slot
        idx = None
        for j in range(len(hw.slot) - 1, -1, -1):
            if hw.slot[j] <= slot:
                idx = j
                break
        if idx is None:
            continue
        remainders.append(max(0.0, hw.total - hw.cum[idx]))
        if hw.total > 0:
            shares.append(hw.cum[idx] / hw.total)
        if len(remainders) >= K_HISTORY:
            break

    if len(remainders) >= 2:
        seasonal = used + median(remainders)
        fb_s = False
    else:
        seasonal = linear
        fb_s = True

    if len(shares) >= 2:
        typ = median(shares)
        shape = used / typ if typ > 0.02 else linear
        fb_h = False
    else:
        shape = linear
        fb_h = True

    # --- tokenusage blend: short (this window) + today-ish (daily_rate) + long ---
    short_rate = used / max(elapsed, 1.0)  # per second
    long_rate = daily_rate / 86400.0 if daily_rate > 0 else 0.0
    block_ratio = elapsed_frac
    short_score = 0.15 + 1.35 * block_ratio
    today_score = 0.25 + 0.85 * (elapsed_frac ** 0.5)
    long_score = max(0.10, min(2.0, 1.20 - 0.95 * block_ratio))
    if long_rate <= 0:
        long_score = 0.0
    tot = short_score + today_score + long_score
    blended_rate = (short_rate * short_score + short_rate * today_score + long_rate * long_score) / tot
    # today component: for weekly, short_rate already is "so far this week";
    # reuse short as today to avoid needing a separate day series here.
    tu = used + blended_rate * remaining_s

    return Forecasts(
        linear=linear,
        seasonal=seasonal,
        shape=shape,
        tu_blend=tu,
        used=used,
        actual=actual,
        elapsed_frac=elapsed_frac,
        weekday=wd,
        hour=hour,
        start_hour=w.start_hour,
        kind=kind,
        fallback_seasonal=fb_s,
        fallback_shape=fb_h,
    )


def daily_avg(events: list[Event], before: datetime) -> float:
    """Mean work-tokens per active local-day in the 30d before `before` (local)."""
    cutoff = before - timedelta(days=30)
    by_day: dict[str, float] = defaultdict(float)
    for e in events:
        if e.local >= before:
            break
        if e.local < cutoff:
            continue
        by_day[e.local.date().isoformat()] += e.work
    if not by_day:
        return 0.0
    return sum(by_day.values()) / len(by_day)


def run_kind(
    events: list[Event],
    windows: list[Window],
    period_s: float,
    kind: str,
) -> list[Forecasts]:
    rows: list[Forecasts] = []
    # events is sorted; daily_avg is O(n) if we naively scan. Precompute prefix by day.
    day_totals: list[tuple[datetime, float]] = []
    cur_day = None
    acc = 0.0
    for e in events:
        d = e.local.replace(hour=0, minute=0, second=0, microsecond=0)
        if cur_day is None:
            cur_day = d
        if d != cur_day:
            day_totals.append((cur_day, acc))
            cur_day = d
            acc = 0.0
        acc += e.work
    if cur_day is not None:
        day_totals.append((cur_day, acc))

    def long_rate_at(t: datetime) -> float:
        cutoff = t - timedelta(days=30)
        vals = [v for d, v in day_totals if cutoff <= d < t.replace(hour=0, minute=0, second=0, microsecond=0)]
        return (sum(vals) / len(vals)) if vals else 0.0

    completed: list[Window] = []
    for w in windows:
        dr = long_rate_at(w.start)
        for i in eval_points(w, period_s):
            rows.append(predict_window(w, i, period_s, completed, dr, kind))
        completed.append(w)
    return rows


WD = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
METHODS = ("linear", "seasonal", "shape", "tu_blend")


def classify(pred: float, actual: float, limit: float) -> tuple[bool, bool]:
    return pred >= limit, actual >= limit


def summarize(name: str, rows: list[Forecasts], limit: float) -> None:
    if not rows:
        print(f"\n## {name}: no rows")
        return
    print(f"\n## {name}  n={len(rows)}  synth_limit(P{int(SYNTH_LIMIT_Q*100)})={limit:,.0f} work-tok")
    n_fb = sum(1 for r in rows if r.fallback_seasonal)
    print(f"   seasonal fallback to linear: {n_fb}/{len(rows)} ({100*n_fb/len(rows):.0f}%)")

    print(f"   {'method':<12} {'MAPE%':>8} {'MedAPE%':>8} {'MAE':>14} {'false-red%':>10} {'false-blue%':>11} {'hit%':>7}")
    for m in METHODS:
        pairs = [(getattr(r, m), r.actual) for r in rows]
        apes = [abs(p - a) / a for p, a in pairs if a > 0]
        medape = 100 * median(apes) if apes else float("nan")
        mae = mae_frac(pairs)
        mp = mape(pairs)
        fr = fb = hits = 0
        for r in rows:
            pred_hit, act_hit = classify(getattr(r, m), r.actual, limit)
            if pred_hit and not act_hit:
                fr += 1
            if act_hit and not pred_hit:
                fb += 1
            if act_hit:
                hits += 1
        n = len(rows)
        print(
            f"   {m:<12} {mp:8.1f} {medape:8.1f} {mae:14,.0f} "
            f"{100*fr/n:9.1f} {100*fb/n:10.1f} {100*hits/n:6.1f}"
        )

    # slice MAPE by weekday (weekly) or start-hour (session)
    if name.startswith("weekly"):
        print("   MAPE% by weekday of evaluation:")
        print(f"      {'wd':<4} " + " ".join(f"{m:>10}" for m in METHODS) + f" {'n':>6}")
        for d in range(7):
            sub = [r for r in rows if r.weekday == d]
            if not sub:
                continue
            cells = []
            for m in METHODS:
                cells.append(f"{mape([(getattr(r,m), r.actual) for r in sub]):10.1f}")
            print(f"      {WD[d]:<4} " + " ".join(cells) + f" {len(sub):6d}")
        print("   false-red% by weekday (linear vs seasonal):")
        print(f"      {'wd':<4} {'linear':>10} {'seasonal':>10} {'n':>6} {'actual-hit%':>12}")
        for d in range(7):
            sub = [r for r in rows if r.weekday == d]
            if not sub:
                continue
            def fr(method):
                return 100 * sum(
                    1 for r in sub
                    if classify(getattr(r, method), r.actual, limit)[0]
                    and not classify(getattr(r, method), r.actual, limit)[1]
                ) / len(sub)
            ah = 100 * sum(1 for r in sub if r.actual >= limit) / len(sub)
            print(f"      {WD[d]:<4} {fr('linear'):10.1f} {fr('seasonal'):10.1f} {len(sub):6d} {ah:12.1f}")
    else:
        print("   MAPE% by session start hour:")
        print(f"      {'hr':<4} " + " ".join(f"{m:>10}" for m in METHODS) + f" {'n':>6}")
        for h in range(24):
            sub = [r for r in rows if r.start_hour == h]
            if len(sub) < 20:
                continue
            cells = [f"{mape([(getattr(r,m), r.actual) for r in sub]):10.1f}" for m in METHODS]
            print(f"      {h:02d}   " + " ".join(cells) + f" {len(sub):6d}")
        print("   MAPE% by elapsed fraction:")
        for lo, hi, lab in ((0.01, 0.25, "early"), (0.25, 0.60, "mid"), (0.60, 0.99, "late")):
            sub = [r for r in rows if lo <= r.elapsed_frac < hi]
            if not sub:
                continue
            cells = [f"{mape([(getattr(r,m), r.actual) for r in sub]):6.1f}" for m in METHODS]
            print(f"      {lab:<6} n={len(sub):5d}  " + "  ".join(f"{m}={c}" for m, c in zip(METHODS, cells)))


def weekday_profile(events: list[Event]) -> None:
    by_wd: dict[int, list[float]] = defaultdict(list)
    by_hour: dict[int, float] = defaultdict(float)
    day_wd: dict[str, tuple[int, float]] = {}
    for e in events:
        key = e.local.date().isoformat()
        wd = e.local.weekday()
        prev = day_wd.get(key)
        if prev is None:
            day_wd[key] = (wd, e.work)
        else:
            day_wd[key] = (wd, prev[1] + e.work)
        by_hour[e.local.hour] += e.work
    for wd, tot in day_wd.values():
        by_wd[wd].append(tot)
    print("\n## weekday profile (work tokens / active day)")
    print(f"   {'wd':<4} {'n':>4} {'median':>14} {'mean':>14} {'p80':>14} {'share%':>7}")
    grand = sum(sum(v) for v in by_wd.values()) or 1
    for d in range(7):
        xs = by_wd.get(d) or []
        if not xs:
            continue
        print(
            f"   {WD[d]:<4} {len(xs):4d} {median(xs):14,.0f} {sum(xs)/len(xs):14,.0f} "
            f"{quantile(xs,0.8):14,.0f} {100*sum(xs)/grand:6.1f}"
        )
    print("   hour-of-day share of all work tokens:")
    tot_h = sum(by_hour.values()) or 1
    bars = " ".join(f"{h:02d}:{100*by_hour[h]/tot_h:4.1f}%" for h in range(24) if by_hour[h] > 0)
    print("   " + bars)


def bench(rows: list[Forecasts], windows: list[Window], period_s: float, events: list[Event]) -> None:
    """Re-run predictors 5k times on a fixed point to get per-call cost."""
    if not windows or not rows:
        return
    w = windows[-1]
    idxs = eval_points(w, period_s)
    if not idxs:
        w = windows[len(windows)//2]
        idxs = eval_points(w, period_s)
    if not idxs:
        return
    i = idxs[len(idxs)//2]
    hist = windows[:-1]
    dr = daily_avg(events, w.start)
    n = 5000
    t0 = time.perf_counter()
    for _ in range(n):
        predict_window(w, i, period_s, hist, dr, w.kind)
    dt = time.perf_counter() - t0
    print(f"   {w.kind} predict_window: {1e6*dt/n:.1f} µs/call  ({n} iters, hist={len(hist)})")


def main() -> None:
    t_all = time.perf_counter()
    print("== pace forecast simulation ==")
    print(f"tz={TZ}  K={K_HISTORY}  cache={CACHE}")

    events: list[Event] = []
    for source, ns in NS_SPECS.items():
        events.extend(load_namespace(ns, source))
    events.sort(key=lambda e: e.ts)
    if not events:
        raise SystemExit("no events")

    span_days = (events[-1].local - events[0].local).total_seconds() / 86400
    print(
        f"events={len(events)}  span={events[0].local.date()} → {events[-1].local.date()} "
        f"({span_days:.0f}d)  work_tok={sum(e.work for e in events):,}  "
        f"total_tok={sum(e.total for e in events):,}"
    )
    weekday_profile(events)

    weekly = build_weekly(events)
    sessions = build_sessions(events)
    now_local = events[-1].local
    n_week_raw, n_sess_raw = len(weekly), len(sessions)
    weekly = [w for w in weekly if w.end <= now_local]
    sessions = [w for w in sessions if w.end <= now_local]
    print(
        f"\nwindows: weekly={len(weekly)}/{n_week_raw} complete  "
        f"session-5h={len(sessions)}/{n_sess_raw} complete  now={now_local}"
    )
    print(
        f"  weekly totals: "
        + ", ".join(f"{w.start.date()}={w.total:,.0f}" for w in weekly)
    )
    sess_tot = [w.total for w in sessions]
    print(
        f"  session n={len(sessions)} median={median(sess_tot):,.0f} "
        f"p80={quantile(sess_tot,0.8):,.0f} mean_events={sum(w.n_events for w in sessions)/max(len(sessions),1):.0f}"
    )

    t1 = time.perf_counter()
    week_rows = run_kind(events, weekly, WEEK_HOURS * 3600, "weekly")
    sess_rows = run_kind(events, sessions, SESSION_HOURS * 3600, "session")
    print(f"\nwalk-forward eval: {len(week_rows)} weekly pts, {len(sess_rows)} session pts "
          f"in {time.perf_counter()-t1:.2f}s")

    week_actuals = [w.total for w in weekly]
    sess_actuals = [w.total for w in sessions]
    week_limit = quantile(week_actuals, SYNTH_LIMIT_Q)
    sess_limit = quantile(sess_actuals, SYNTH_LIMIT_Q)

    summarize("weekly (ISO week, work tokens)", week_rows, week_limit)
    summarize("session (5h blocks, work tokens)", sess_rows, sess_limit)

    print("\n## runtime (predictors only, history already built)")
    bench(week_rows, weekly, WEEK_HOURS * 3600, events)
    bench(sess_rows, sessions, SESSION_HOURS * 3600, events)
    print(f"\nwall {time.perf_counter()-t_all:.2f}s")

    # Honest caveats
    print(
        "\n## caveats\n"
        "  - Quantity is local work-tokens, not Anthropic/Codex quota %. Quota-weighting can differ.\n"
        "  - Synth limit = P80 of completed window totals — a stand-in for 'would I burst'.\n"
        "  - Codex cache is almost empty here; Claude+Grok dominate.\n"
        "  - Seasonal/shape need ≥2 completed comparable cycles; until then they ARE linear."
    )


if __name__ == "__main__":
    main()
