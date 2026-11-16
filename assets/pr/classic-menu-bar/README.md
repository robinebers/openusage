# Classic menu bar evidence

The PNGs are rendered UI evidence exported by `MenuBarEvidenceTests`, using synthetic Claude,
ChatGPT, and Cursor readings. They contain no real accounts, names, or email addresses.

- `before.png`: reconstructs the app-icon fallback on main for healthy metrics with no Priority pins.
  The fixture asserts that all four Priority sections used by main are empty.
- `after.png`: the actual image from `MenuBarContentBuilder` and `MenuBarStripRenderer` on this branch,
  with Always Show on, Max Items set to 3, and usage displayed as Left.
- `test-results.txt`: selected lines from the passing quiet XCTest run, with the reproduction command.

These are rendered test fixtures, not desktop screenshots or live provider responses. Run the command
in `test-results.txt` to regenerate them; `OPENUSAGE_EVIDENCE_DIR` chooses the output directory.
