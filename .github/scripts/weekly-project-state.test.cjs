'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const helpers = require('./weekly-project-state.cjs')._test;

test('formats the report date in Pacific Time', () => {
  assert.equal(helpers.localDate(new Date('2026-09-04T16:00:00Z'), 'America/Los_Angeles'), '2026-09-04');
});

test('extracts explicit closing references', () => {
  assert.deepEqual(helpers.closingIssues('Closes #30. Fixes #31 and resolves #32.'), [30, 31, 32]);
});

test('prefers an outcome section for a concise summary', () => {
  assert.equal(
    helpers.bodySummary('## Outcome\n\nServer-side hardening for `oppi doctor`.\n\n## Tests\n\n- Covered.', 'fallback'),
    'Server-side hardening for oppi doctor.',
  );
});

test('treats workflow approval as blocking', () => {
  assert.deepEqual(
    helpers.checkState([], [{ workflow_id: 1, status: 'completed', conclusion: 'action_required', updated_at: '2026-09-01' }], []),
    { label: 'workflow approval required', blocking: true },
  );
});

test('uses the latest check run by name', () => {
  assert.deepEqual(
    helpers.checkState([
      { id: 1, name: 'hygiene', app: { slug: 'github-actions' }, status: 'completed', conclusion: 'failure', completed_at: '2026-09-01T00:00:00Z' },
      { id: 2, name: 'hygiene', app: { slug: 'github-actions' }, status: 'completed', conclusion: 'success', completed_at: '2026-09-01T01:00:00Z' },
    ], [], []),
    { label: 'checks passing', blocking: false },
  );
});

test('parses hidden report metadata', () => {
  assert.deepEqual(
    helpers.metadata('<!-- oppi-weekly-project-state-meta {"generatedAt":"2026-09-01T00:00:00Z","since":"2026-08-25T00:00:00Z"} -->'),
    { generatedAt: '2026-09-01T00:00:00Z', since: '2026-08-25T00:00:00Z' },
  );
});
