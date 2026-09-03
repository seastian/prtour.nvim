# prtour

A Neovim plugin for reviewing pull requests — and local, not-yet-pushed changes — as a guided, one-keypress-at-a-time tour through the diff's hunks.

## Language

**Tour**:
One guided review session: an ordered walk through a diff's hunks. A tour is either a PR tour or a local review.
_Avoid_: session, review (too vague on its own)

**Hunk**:
A contiguous changed region of one file, the atomic unit a tour steps through. Identified for progress purposes by `sha256(path + hunk body)`, so its identity survives rebases and line shifts.

**Step**:
A titled group of related hunks with a one-sentence reviewer note. Claude Code orders the hunks into steps; the ordering is the manifest.

**Manifest**:
The cached, hunk-hash-keyed reading order (list of steps) for a tour. Generated once by Claude Code, stored locally, reused on resume so ordering is never recomputed unless hunks changed.

**Seen**:
A hunk the reviewer has already visited in a tour, tracked locally by hunk hash. Content-addressed, so unrelated edits/force-pushes don't reset it. A hunk in a tour is in one of three states: *unseen*, *seen-here* (walked in this tour), or *reviewed-earlier*.

**Reviewed-earlier**:
A hunk not yet walked in the current tour but whose identical content was seen in a *different* same-repo tour (e.g. a local review before the PR). Derived at load time as an overlay from other tours' seen sets — never stored in this tour's own seen set. Rendered distinctly and pre-seeded as seen so the frontier parks on genuinely-new hunks. See [[ADR-0001]].

**Walked-here / Covered**:
Two progress figures for a tour. *Walked-here* = hunks stepped through in this tour. *Covered* = walked-here ∪ reviewed-earlier. A tour is complete when everything is *covered*; the dashboard leads with covered.

**PR tour**:
A tour of an open GitHub pull request, checked out locally and diffed against its base.

**Local review**:
A tour of local changes before any PR exists, diffed against a base. When the working tree is dirty the base defaults to `HEAD` (review just the uncommitted changes) but can be toggled (`<Tab>` on the dashboard card) to the default branch (review the whole branch — committed work plus the dirt); when it's clean the base is the merge-base of the default branch (review the branch so far), and another base may be chosen. Untracked files are included.
_Avoid_: local mode

**Launcher**:
What the `\` key opens outside a tour: the entry screen for starting or resuming tours. (The evolving design turns this into a full-buffer **dashboard** with Resume and Start sections.)

**Resume (section)**:
The dashboard section listing this repo's unfinished tours (PR tours and local reviews with progress still saved), most-recently-worked-first and capped to the last ~10, so any can be continued where it was left off. No manual delete; stale entries age out via the cache pruner.

**Start (section)**:
The dashboard section listing fresh tours you could begin now: open GitHub PRs, and a local-review card (working tree vs `HEAD` when dirty — `<Tab>`-toggleable to vs the default branch — else `HEAD` vs the default branch).
