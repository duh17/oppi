# Changelog fragments

Entries for the next release live here, one file per change, until the release cut moves them into [`CHANGELOG.md`](../CHANGELOG.md). Two branches that each add a fragment never edit the same file, so they merge without a conflict.

- Put the fragment in the folder for its section: `added/`, `changed/`, `fixed/`, `removed/`, or `migration-notes/`. A change that belongs in two sections adds a fragment to each.
- Name it after the change, such as `fixed/outline-jump-long-chat.md`. A name another change already uses is a conflict.
- Its content is the bullet itself, written to the rules in [Changelog style](../CHANGELOG.md#changelog-style): `- **Client:** …`. One file may hold several bullets for one change.
- When later work changes an unreleased feature, edit or delete its fragment instead of adding one that contradicts it.

Within a section, fragments appear in file-name order. The release lane may rename them to set the order.

```bash
bun scripts/release/changelog.ts preview                  # print the next release's sections
bun scripts/release/changelog.ts cut --version 0.56.0     # write them into CHANGELOG.md, delete the fragments
```

`cut` adds `## [0.56.0] - <today>` below `[Unreleased]` (`--date YYYY-MM-DD` overrides the date). The release lane then writes the release's target line and summary under that heading and commits `CHANGELOG.md` with the deleted fragments in the cut commit.
