# Local divergences from upstream termbox2

This file tracks any in-tree edits to vendored termbox2 sources, so the next
vendor bump can re-apply or drop them deliberately.

Upstream: https://github.com/termbox/termbox2

Search the source for `// fen patch:` to locate change sites.

## Active patches

### keypad-Enter (`\x1bOM`) → `TB_KEY_ENTER`

- **File:** `termbox2.h`, inside `init_cap_trie()` (after the
  `builtin_mod_caps` loop, before `return TB_OK`).
- **What:** One additional `cap_trie_add("\x1bOM", TB_KEY_ENTER, 0)` call.
- **Why:** termbox2 sends DECPAM (smkx, `\033=`) on init so it can decode
  arrows/F-keys via SS3-prefixed sequences. In application keypad mode,
  the keypad Enter key emits `\x1bOM`. termbox2's cap trie has entries for
  arrows, Home/End, and F1-F4 in this family but no entry for `\x1bOM`,
  so the parser drops the leading ESC and the bare `OM` leaks into input.
  Affects any terminal where the hardware Enter is keymapped to
  `KP_Enter` — observed on osso-xterm on the Nokia N900.
- **Upstream status:** not yet filed.
- **Reapply on bump:** the surrounding code is small and stable; re-add
  the four-line block in the same location. Drop this entry if upstream
  takes an equivalent fix.
