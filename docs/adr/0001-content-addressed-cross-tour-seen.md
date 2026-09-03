# Content-addressed cross-tour seen

## Context

A hunk's seen-identity is `sha256(path + hunk body)`, so identical content has the same hash across different tours of the same repo. This lets one tour recognise content a *different* tour already reviewed — the payoff case being: review an AI agent's uncommitted changes as a **local review**, push, open a PR, and do a final pass where the parts you already saw are recognised rather than re-read. It also handles PRs whose base differs from the repo default, where much of the diff overlaps content reviewed elsewhere.

## Decision

Cross-tour "reviewed-earlier" knowledge is a **derived overlay**, not stored state:

- Each tour's own `seen` set records **only** the hunks walked in *that* tour (kept pure).
- At every tour load, the overlay is recomputed as `union(other same-repo tours' seen sets) − (this tour's own seen)`, read from the existing `progress-*.json` files (no new storage format). Provenance comes from the source tour's label.
- A hunk therefore has **three states**: *unseen*, *seen-here*, *reviewed-earlier* (rendered distinctly, pre-seeded as seen so the `]u` frontier parks on genuinely-new hunks, still freely revisitable).
- Progress is two figures: **walked-here** (stepped through in this tour) and **covered** (`walked-here ∪ reviewed-earlier`). A tour is **complete when everything is covered**, not only when walked-here.

## Considered options

- **Dedicated per-repo reviewed-ledger file** (hash → when/source), written by every tour. Rejected: a new persisted format and migration for something derivable from files we already read; the derived overlay also stays live automatically when a *later* tour reviews more content.
- **Bake reviewed-earlier into the tour's own `seen` set at creation.** Rejected: blurs provenance and goes stale — a subsequent local review wouldn't retroactively show as coverage.

## Consequences

- Opening a PR whose content was fully reviewed in a prior local review shows as immediately complete.
- Computing true per-PR coverage on the launcher would require diffing every open PR, so the dashboard uses only a cheap branch-name-match hint ("reviewed locally"); exact per-hunk marks appear once inside the tour, where the diff is computed anyway.
