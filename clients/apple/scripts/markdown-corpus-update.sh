#!/usr/bin/env bash
# Rewrite the tree and render sections of every Markdown golden-corpus file
# (OppiTests/Fixtures/markdown-corpus) from the current parser and renderer.
# The only writer of those files: tests compare and never record. Review the
# diff, and keep or drop each file's `known-wrong:` notes by hand.
set -euo pipefail
apple="$(cd "$(dirname "$0")/.." && pwd)"
root="$(git -C "$apple" rev-parse --show-toplevel)"
export TEST_RUNNER_OPPI_MARKDOWN_CORPUS_RECORD_DIR="$apple/OppiTests/Fixtures/markdown-corpus"
exec "$apple/scripts/sim-pool.sh" run --root "$root" -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -only-testing:'OppiTests/MarkdownCorpusTests/parserAndRendererMatchTheCorpus(_:)'
