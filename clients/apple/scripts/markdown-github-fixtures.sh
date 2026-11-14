#!/usr/bin/env bash
# Rewrite GitHub's rendering of every inline-HTML differential fixture
# (OppiTests/Fixtures/markdown-github/github-html-*.md -> .html) with GitHub's
# Markdown API, in the comment mode (`gfm`). Read-only on GitHub; needs a
# signed-in `gh`. Tests read the saved HTML and never call GitHub. Review the
# diff before keeping it.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)/OppiTests/Fixtures/markdown-github"
for source in "$dir"/github-html-*.md; do
  gh api -X POST /markdown -F text=@"$source" -f mode=gfm > "${source%.md}.html"
done
