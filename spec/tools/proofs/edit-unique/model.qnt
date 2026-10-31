// Proof model: edit's old_string uniqueness count (#658).
//
// The `ov` machine of ../../model.qnt, widened: every content of N = 6 bytes
// over {a, b} and every old_string among the self-overlapping patterns "aa"
// and "aba" (and "ab", which cannot overlap itself).  One step (pick) chooses
// them and counts; the property is then checked for all of them at once.
//
// Code: extensions/behaviors/kernel/builtin-tools/edit.fnl (find-all,
// validate-edits): after a hit at pos the search resumes at pos + #old, so
// overlapping occurrences are not counted.
//
// The #658 fix: resume at pos + 1.
module editUnique {
  const FIXES: Set[str]

  pure val N = 6        // content bytes
  pure val MAXP = 3     // longest pattern
  pure val PATTERNS = Set(["a", "a"], ["a", "b"], ["a", "b", "a"])

  var ran: bool
  var content: List[str]
  var pat: List[str]
  var found: int        // what find-all reports
  var actual: int       // every start position where pat occurs

  // pat occurs at i.  Constant-bound fold (Apalache-friendly).
  pure def occursAt(c: List[str], p: List[str], i: int): bool =
    i + p.length() <= N and
    range(0, MAXP).foldl(true, (ok, j) =>
      ok and (j >= p.length() or c[i + j] == p[j]))

  // find-all: scan left to right; after a hit, skip ahead.
  pure def countHits(c: List[str], p: List[str], fix: bool): int =
    range(0, N).foldl({ n: 0, next: 0 }, (acc, i) =>
      if (i >= acc.next and occursAt(c, p, i))
        { n: acc.n + 1, next: if (fix) i + 1 else i + p.length() }
      else acc
    ).n

  pure def actualCount(c: List[str], p: List[str]): int =
    range(0, N).foldl(0, (n, i) => if (occursAt(c, p, i)) n + 1 else n)

  action init = all {
    ran' = false, content' = [], pat' = [], found' = 0, actual' = 0,
  }

  action runWith(c: List[str], p: List[str]): bool = all {
    not(ran),
    ran' = true, content' = c, pat' = p,
    found' = countHits(c, p, FIXES.contains("658")),
    actual' = actualCount(c, p),
  }

  action pick = {
    nondet c0 = Set("a", "b").oneOf()
    nondet c1 = Set("a", "b").oneOf()
    nondet c2 = Set("a", "b").oneOf()
    nondet c3 = Set("a", "b").oneOf()
    nondet c4 = Set("a", "b").oneOf()
    nondet c5 = Set("a", "b").oneOf()
    nondet p = PATTERNS.oneOf()
    runWith([c0, c1, c2, c3, c4, c5], p)
  }

  action stutter = all {
    ran,
    ran' = ran, content' = content, pat' = pat, found' = found, actual' = actual,
  }

  action step = any { pick, stutter }

  // edit accepts an old_string only when it occurs exactly once.
  val uniqueMatchIsUnique = (ran and found == 1) implies actual == 1

  // Stronger: the reported count is the true count (so "not unique" lists
  // every match site).
  val countIsExact = ran implies found == actual

  // Skipping ahead can only miss matches, never invent one.
  val countNeverOver = ran implies found <= actual
}

module current { import editUnique(FIXES = Set()).* }
module fixed { import editUnique(FIXES = Set("658")).* }
