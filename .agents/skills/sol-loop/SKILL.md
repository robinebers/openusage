---
name: sol-loop
description: Review a change in rounds with a separate reviewer agent until it approves or the budget runs out. Use when the user says "sol loop" or asks for a review loop before shipping.
---

# sol-loop

A separate reviewer agent checks your change in rounds. Fix minimally, avoid scope creep, push back when it is wrong.

## Budget

- 3 rounds; 5 only if the user asks, or for security, auth, data loss, or concurrency while a blocker or should stays open with evidence.
- Stop early if a round returns only nits. Declined nits and comment, doc, or format-only fixes need no new round.
- One reviewer at a time, and it starts no agents of its own.
- Keep a ledger: id, severity, outcome.

## 1. Scope

Run `git status --short`. Never stash, discard, or include unrelated changes; if they don't separate cleanly by path, stop and ask.

After `git fetch origin`, base is `git merge-base HEAD origin/<PR base or default branch>`. For a PR, `HEAD` must be the PR head or ahead only by this change. The change is base to working tree, untracked files included; use the same diff every round.

State intent and out-of-scope in 1-2 sentences. Run the covering checks (`swift build`, `script/test_quiet.sh --filter <Suite>`); never send code the change breaks.

## 2. Start the reviewer

Use the strongest model you can run, ideally not the one that wrote the change. If the user named a model you cannot run, report it; do not substitute.

If you can start a separate agent (subagent, background agent, new thread), run the reviewer there and keep its id. Otherwise give the user the brief to run in another session. A self-review never counts as a round.

While it runs, do not edit scoped files, poll, or start a second reviewer. A timeout, error, or no reply is not approval; stop it and restart with the ledger.

Round 1 brief (the reviewer has none of your context):

```
Review only. Do not edit, commit, push, comment on PRs, or start other agents.
Repo: <abs path> Base: <sha> Intent: <intent> Out of scope: <scope> Checks: <results>
See: git diff <base> [-- <paths>]; git status --short (read untracked).
Read surrounding code. Find bugs, broken callers, mismatch with intent.
Skip style unless it hides a bug. Hold to the smallest change. Flag code,
tests, or guards the intent does not need. Other paths, rare cases, small
perf, extra compat: nits.
blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest.
Reply:
VERDICT: APPROVE or CHANGES
S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)
```

## 3. Answer findings

Judge each finding and severity yourself; another path, rare case, or small cost is a nit whatever its label.

- Agree: smallest fix, preferring delete or narrow over a new lock, cache, helper, or option. One focused test that fails without the fix, if the intent needs it.
- Disagree: say why with evidence (file:line, test, output).
- Out of scope or nit: decline in one line, list as follow-up.

Re-run checks and `git diff --shortstat <base>`; if review grew the diff, cut first. Never agree just to end the loop.

## 4. Next round

Only if budget remains and a blocker or should is open or behavior code changed since the last approval. Send the same or a fresh reviewer the round 1 brief, the ledger (`fixed:` / `disagree:` / `declined:` with evidence), and the change since last round. It checks open ids and changed code only, marking each old id `resolved` or `still open: <reason>`.

## 5. Stop and ship

Agreed: APPROVE on the current diff, nothing above nit open, no concern of your own. Stuck: an item disputed after two replies, or budget spent; show both sides in 2-3 lines each and let the user decide. Budget end is not approval.

Never push during the loop; after agreement, push only if the user asked. On a PR, add `Reviewed with sol-loop: <N> rounds with <model>. Verdict: approved` to the description.

Report: rounds, reviewer model, diff size before and after, fixed and declined findings with reasons, pushed or not.

Adapted from sol-loop in t3dotgg/tstack (MIT, Copyright (c) 2026 Theo Browne).
