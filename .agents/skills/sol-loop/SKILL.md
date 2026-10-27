---
name: sol-loop
description: Review a change in rounds with GPT 6.1 Sol as a separate reviewer until it approves or the budget runs out. Use when the user says "sol loop" or asks for a Sol review loop before shipping.
---

# sol-loop

GPT 6.1 Sol reviews your change in rounds. Make the smallest changes that answer it, avoid scope creep, and push back when it is wrong.

## Budget

- 3 rounds. Round 1 is full; later rounds check only changed code and open findings.
- 5 only if the user asks, or for security, permissions, auth, data loss, or state/concurrency while a blocker or should stays open with evidence.
- Stop early if a round returns only nits. Declined nits and comment, doc, or format-only fixes need no new round.
- One reviewer only. Sol must not start subagents or reviewers.
- Keep a ledger: id, severity, outcome, usage if returned. Never guess usage.

## 1. Scope

Run `git status --short`. Never stash, discard, or include unrelated changes; if they don't separate cleanly by path, stop and ask.

After `git fetch origin`, base is `git merge-base HEAD origin/<PR base or default branch>`. For a PR, `HEAD` must be the PR head or ahead only by this change. No remote: a base the user names, or `HEAD` for uncommitted changes only. The change is base to working tree, untracked files included; use the same diff every round.

State intent and out-of-scope in 1-2 sentences. Run the covering checks (`swift build`, `script/test_quiet.sh --filter <Suite>`); never send code the change breaks. Note missing or already-failing checks in the brief.

## 2. Start Sol

The reviewer is GPT 6.1 Sol, unless the user names another Sol version. Reach it the way your harness allows:

- Capy: a subagent or thread on model `openai/gpt-6.1-sol`; keep its path or code for later rounds.
- Cursor: a background agent or new chat with GPT 6.1 Sol selected.
- Claude Code and other harnesses without GPT models: Codex CLI, `codex exec -m gpt-6.1-sol -` with the brief on stdin (read-only sandbox by default). Note the session id it prints; `codex exec resume <SESSION_ID>` continues it.
- Anything else: give the user the brief to run in a Sol session and wait for the reply.

If no route reaches Sol, stop and tell the user. Never substitute another model, and never count a self-review as a round. Record provider, model, and effort only if your harness shows them.

Do not edit scoped files while Sol runs. Wait for the result; do not poll or start a second reviewer. A timeout, error, or no reply is not approval. On failure, cancel, confirm it stopped, and restart with the ledger.

Round 1 brief (Sol has none of your context):

```
Review only. Do not edit, commit, push, comment on PRs, or start subagents.
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

Check each finding and severity yourself; another path, rare case, or small cost is a nit whatever its label.

- Agree: smallest fix, preferring delete or narrow over a new lock, cache, helper, or option. Fix the case that happened. One focused test that fails without the fix, if the intent needs it.
- Disagree: say why with evidence (file:line, test, output).
- Out of scope or nit: decline in one line, list as follow-up.

Update the ledger. Re-run checks and `git diff --shortstat <base>`; if review grew the diff, cut first. Never agree just to end the loop.

## 4. Next round

Only if budget remains and a blocker or should is open, behavior code changed, or approval does not cover the current behavior diff. Follow up the same Sol session, or start a fresh one. Send the round 1 brief, the ledger (`fixed:` / `disagree:` / `declined:` with evidence), the same base diff, and the change since last round. Tell Sol: open ids and changed code only, marking each old id `resolved` or `still open: <reason>`.

## 5. Stop and ship

Agreed: APPROVE on the current behavior diff, no blocker or should open, no concern of your own. Stuck: an item disputed after two replies, or budget spent; show both sides in 2-3 lines each and let the user decide. Budget end is not approval.

Never push during the loop; after agreement, push only if the user asked to push, ship, or update the PR. On a PR, add to the description:

`Reviewed with sol-loop: <N> rounds with GPT 6.1 Sol. Sol verdict: approved`

Add `on <effort>` only if verified.

Report: rounds with GPT 6.1 Sol, what Sol changed, diff size before and after, fixed and declined findings with reasons, usage if shown (else say not), pushed or not.

Adapted from sol-loop in t3dotgg/tstack (MIT, Copyright (c) 2026 Theo Browne).
