'use strict';

const TRACKER = '<!-- oppi-weekly-project-state-tracker -->';
const REPORT = '<!-- oppi-weekly-project-state-report:';
const META = '<!-- oppi-weekly-project-state-meta ';
const DAY = 86_400_000;
const BLOCK_LABELS = new Set(['blocked', 'blocker', 'critical', 'p0', 'priority: p0', 'status: blocked']);
const DECISION_LABELS = new Set(['architecture', 'decision', 'design', 'proposal', 'rfc']);
const PRIORITY_LABELS = new Set(['next', 'p0', 'p1', 'priority: high', 'priority: p0', 'priority: p1', 'roadmap']);
const FAILURES = new Set(['action_required', 'cancelled', 'error', 'failure', 'startup_failure', 'stale', 'timed_out']);

const boundedInt = (value, fallback, min, max) => {
  const number = Number.parseInt(value || '', 10);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
};

const parts = (date, timeZone) => Object.fromEntries(
  new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date).map((part) => [part.type, part.value]),
);

const localDate = (date, timeZone) => {
  const value = parts(date, timeZone);
  return `${value.year}-${value.month}-${value.day}`;
};

const fullDate = (date, timeZone) => new Intl.DateTimeFormat('en-US', {
  timeZone,
  weekday: 'long',
  year: 'numeric',
  month: 'long',
  day: 'numeric',
}).format(date);

const dateTime = (date, timeZone) => new Intl.DateTimeFormat('en-US', {
  timeZone,
  year: 'numeric',
  month: 'short',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
  timeZoneName: 'short',
}).format(date);

const shortDate = (value, timeZone) => new Intl.DateTimeFormat('en-US', {
  timeZone,
  month: 'short',
  day: 'numeric',
}).format(new Date(value));

const age = (value, now) => {
  const hours = Math.max(0, Math.floor((now - new Date(value)) / 3_600_000));
  if (hours < 1) return 'under 1h ago';
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
};

const inline = (value) => String(value || '')
  .replace(/[\r\n\t]+/g, ' ')
  .replace(/\s+/g, ' ')
  .trim()
  .replace(/\\/g, '\\\\')
  .replace(/([\[\]_*`])/g, '\\$1')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;');

const plain = (value) => String(value || '')
  .replace(/<!--[\s\S]*?-->/g, ' ')
  .replace(/<[^>]+>/g, ' ')
  .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
  .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
  .replace(/```[\s\S]*?```/g, ' ')
  .replace(/`([^`]+)`/g, '$1')
  .replace(/^\s{0,3}#{1,6}\s+/gm, '')
  .replace(/^\s*(?:[-*+]|\d+[.)])\s+/gm, '')
  .replace(/[>*_~]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

const sentence = (value) => {
  const text = inline(value);
  return !text || /[.!?…]$/.test(text) ? text : `${text}.`;
};

function section(body, names) {
  const accepted = new Set(names.map((name) => name.toLowerCase()));
  const lines = String(body || '').split(/\r?\n/);
  const selected = [];
  let active = false;
  for (const line of lines) {
    const heading = line.match(/^\s{0,3}#{2,6}\s+(.+?)\s*#*\s*$/);
    if (heading) {
      if (active) break;
      active = accepted.has(plain(heading[1]).toLowerCase());
      continue;
    }
    if (active) selected.push(line);
  }
  return selected.join('\n');
}

function firstParagraph(value) {
  const lines = String(value || '').split(/\r?\n/);
  const result = [];
  let code = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (line.startsWith('```')) {
      code = !code;
      continue;
    }
    if (code || line.startsWith('<!--') || line.startsWith('<')) continue;
    if (!line) {
      if (result.length) break;
      continue;
    }
    result.push(line);
    if (result.join(' ').length >= 260 || (/[.!?]$/.test(line) && result.join(' ').length >= 60)) break;
  }
  const text = plain(result.join(' '));
  return text.length > 260 ? `${text.slice(0, 259).trimEnd()}…` : text;
}

function bodySummary(body, fallback) {
  for (const name of ['outcome', 'decision', 'summary', 'proposed scope', 'why', 'problem / implementation need']) {
    const value = firstParagraph(section(body, [name]));
    if (value) return value;
  }
  return firstParagraph(body) || plain(fallback);
}

const labelNames = (item) => (item.labels || [])
  .map((label) => (typeof label === 'string' ? label : label.name))
  .filter(Boolean)
  .map((name) => name.toLowerCase());

const hasLabel = (item, set) => labelNames(item).some((name) => set.has(name));
const hasHeading = (body, names) => names.some((name) => new RegExp(`^\\s{0,3}#{2,6}\\s+${name}\\s*#*\\s*$`, 'im').test(body || ''));
const isDecision = (item) => hasLabel(item, DECISION_LABELS)
  || /^(decision|proposal|rfc)\s*:/i.test(item.title || '')
  || hasHeading(item.body, ['decision', 'open questions?', 'proposal', 'proposed scope', 'rfc']);
const isBlocker = (item) => hasLabel(item, BLOCK_LABELS) || /\b(?:blocked by|status\s*:\s*blocked)\b/i.test(item.body || '');

const closingIssues = (body) => [...String(body || '').matchAll(/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)/gi)]
  .map((match) => Number(match[1]));

function reviewState(reviews) {
  const current = new Map();
  for (const review of [...reviews].sort((a, b) => new Date(a.submitted_at || 0) - new Date(b.submitted_at || 0))) {
    const login = review.user?.login;
    if (!login) continue;
    if (review.state === 'DISMISSED') current.delete(login);
    if (review.state === 'APPROVED' || review.state === 'CHANGES_REQUESTED') current.set(login, review.state);
  }
  const entries = [...current.entries()];
  return {
    approvals: entries.filter(([, state]) => state === 'APPROVED').map(([login]) => login),
    changes: entries.filter(([, state]) => state === 'CHANGES_REQUESTED').map(([login]) => login),
  };
}

function latest(items, key, time) {
  const values = new Map();
  for (const item of items || []) {
    const id = key(item);
    const prior = values.get(id);
    if (id && (!prior || new Date(time(item) || 0) >= new Date(time(prior) || 0))) values.set(id, item);
  }
  return [...values.values()];
}

function checkState(checkRuns, workflowRuns, statuses) {
  const records = [
    ...latest(checkRuns, (run) => `${run.app?.slug || 'checks'}:${run.name || run.id}`, (run) => run.completed_at || run.updated_at)
      .map((run) => ({ status: run.status, conclusion: run.conclusion })),
    ...latest(workflowRuns, (run) => String(run.workflow_id || run.name || run.id), (run) => run.run_started_at || run.updated_at)
      .map((run) => ({ status: run.status, conclusion: run.conclusion })),
    ...latest(statuses, (status) => status.context, (status) => status.updated_at)
      .map((status) => ({ status: status.state === 'pending' ? 'in_progress' : 'completed', conclusion: status.state })),
  ];
  if (!records.length) return { label: 'no checks reported', blocking: false };
  if (records.some((record) => record.conclusion === 'action_required')) return { label: 'workflow approval required', blocking: true };
  const failing = records.filter((record) => FAILURES.has(record.conclusion)).length;
  if (failing) return { label: `${failing} failing check${failing === 1 ? '' : 's'}`, blocking: true };
  const pending = records.filter((record) => record.status !== 'completed' || !record.conclusion || record.conclusion === 'pending').length;
  if (pending) return { label: `${pending} pending check${pending === 1 ? '' : 's'}`, blocking: true };
  return { label: 'checks passing', blocking: false };
}

async function safe(core, message, fallback, call) {
  try {
    return await call();
  } catch (error) {
    core.warning(`${message}: ${error.message}`);
    return fallback;
  }
}

async function mapLimit(items, limit, worker) {
  const result = new Array(items.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      result[index] = await worker(items[index]);
    }
  }));
  return result;
}

async function enrichPull(github, core, owner, repo, pull) {
  const number = pull.number;
  const [detail, reviews, checks, workflows, statuses] = await Promise.all([
    safe(core, `PR #${number}`, pull, async () => (await github.rest.pulls.get({ owner, repo, pull_number: number })).data),
    safe(core, `Reviews for PR #${number}`, [], () => github.paginate(github.rest.pulls.listReviews, { owner, repo, pull_number: number, per_page: 100 })),
    safe(core, `Checks for PR #${number}`, [], async () => (await github.rest.checks.listForRef({ owner, repo, ref: pull.head.sha, filter: 'latest', per_page: 100 })).data.check_runs || []),
    safe(core, `Workflow runs for PR #${number}`, [], async () => (await github.rest.actions.listWorkflowRunsForRepo({ owner, repo, head_sha: pull.head.sha, per_page: 100 })).data.workflow_runs || []),
    safe(core, `Statuses for PR #${number}`, [], async () => (await github.rest.repos.getCombinedStatusForRef({ owner, repo, ref: pull.head.sha, per_page: 100 })).data.statuses || []),
  ]);
  const review = reviewState(reviews);
  const ci = checkState(checks, workflows, statuses);
  const blockers = [];
  if (detail.draft) blockers.push('draft');
  if (hasLabel(detail, BLOCK_LABELS)) blockers.push('explicitly labeled blocked');
  if (detail.mergeable === false || detail.mergeable_state === 'dirty') blockers.push('merge conflict');
  if (review.changes.length) blockers.push(`changes requested by ${review.changes.map((login) => `@${login}`).join(', ')}`);
  if (ci.blocking) blockers.push(ci.label);
  if (detail.mergeable_state === 'blocked' && !blockers.length) blockers.push('merge requirements unmet');
  return {
    ...detail,
    summary: bodySummary(detail.body, detail.title),
    review,
    ci,
    blockers: [...new Set(blockers)],
    closingIssues: closingIssues(detail.body),
  };
}

const reportMarker = (date) => `${REPORT}${date} -->`;
const metadata = (body) => {
  const match = String(body || '').match(/<!-- oppi-weekly-project-state-meta (\{[^\n]+\}) -->/);
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
};

async function trackerIssue(github, owner, repo) {
  const items = await github.paginate(github.rest.issues.listForRepo, {
    owner, repo, state: 'all', sort: 'updated', direction: 'desc', per_page: 100,
  });
  return items.find((item) => !item.pull_request && String(item.body || '').includes(TRACKER)) || null;
}

const prLink = (owner, repo, number) => `[#${number}](https://github.com/${owner}/${repo}/pull/${number})`;
const issueLink = (owner, repo, number) => `[#${number}](https://github.com/${owner}/${repo}/issues/${number})`;

function inferredSteps(openPulls, openIssues, owner, repo) {
  const steps = [];
  const ready = openPulls.filter((pull) => !pull.draft && !pull.blockers.length);
  const blocked = openPulls.filter((pull) => pull.blockers.length);
  const decisions = openIssues.filter(isDecision);
  const covered = openIssues.filter((issue) => openPulls.some((pull) => pull.closingIssues.includes(issue.number)));
  const priority = openIssues.filter((issue) => hasLabel(issue, PRIORITY_LABELS) && !decisions.includes(issue));
  if (ready.length) steps.push(`Review and merge ${ready.map((pull) => prLink(owner, repo, pull.number)).join(', ')}.`);
  if (blocked.length) steps.push(`Clear merge gates for ${blocked.map((pull) => prLink(owner, repo, pull.number)).join(', ')}.`);
  if (covered.length) steps.push(`Land linked fixes and close ${covered.map((issue) => issueLink(owner, repo, issue.number)).join(', ')}.`);
  if (decisions.length) steps.push(`Resolve scope for ${decisions.map((issue) => issueLink(owner, repo, issue.number)).join(', ')} before implementation expands.`);
  if (priority.length) steps.push(`Advance prioritized issues ${priority.map((issue) => issueLink(owner, repo, issue.number)).join(', ')}.`);
  if (!steps.length && openIssues.length) steps.push(`Triage ${openIssues.slice(0, 5).map((issue) => issueLink(owner, repo, issue.number)).join(', ')}.`);
  if (!steps.length) steps.push('Define the next repository milestone or open the next scoped implementation issue.');
  return steps.map((step, index) => `${index + 1}. ${step}`).join('\n');
}

function render({ owner, repo, merged, openPulls, openIssues, milestones, since, now, timeZone, runUrl }) {
  const decisions = openIssues.filter(isDecision);
  const blockerIssues = openIssues.filter(isBlocker);
  const blockedPulls = openPulls.filter((pull) => pull.blockers.length);

  const mergedText = merged.length
    ? merged.map((pull) => {
      const files = Number.isFinite(pull.changed_files) ? ` across ${pull.changed_files} file${pull.changed_files === 1 ? '' : 's'}` : '';
      const stats = Number.isFinite(pull.additions) ? `; +${pull.additions}/−${pull.deletions}${files}` : '';
      return `- ${prLink(owner, repo, pull.number)} **${inline(pull.title)}** — ${sentence(pull.summary)} _(merged ${shortDate(pull.merged_at, timeZone)} by @${inline(pull.user?.login || 'unknown')}${stats})_`;
    }).join('\n')
    : 'No pull requests merged in this reporting window.';

  const pullsText = openPulls.length
    ? openPulls.map((pull) => {
      const state = pull.blockers.length
        ? `**waiting:** ${pull.blockers.join('; ')}`
        : (pull.mergeable === true || ['clean', 'unstable'].includes(pull.mergeable_state)) ? 'mergeable' : 'open';
      const review = pull.review.approvals.length
        ? `${pull.review.approvals.length} approval${pull.review.approvals.length === 1 ? '' : 's'}`
        : (pull.requested_reviewers || []).length ? `${pull.requested_reviewers.length} requested reviewer${pull.requested_reviewers.length === 1 ? '' : 's'}` : 'no formal review yet';
      const size = Number.isFinite(pull.additions)
        ? ` · +${pull.additions}/−${pull.deletions}${Number.isFinite(pull.changed_files) ? ` in ${pull.changed_files} file${pull.changed_files === 1 ? '' : 's'}` : ''}`
        : '';
      const detail = plain(pull.summary) !== plain(pull.title) ? `\n  - ${sentence(pull.summary)}` : '';
      return `- ${prLink(owner, repo, pull.number)} **${inline(pull.title)}** — ${state} · ${pull.ci.label} · ${review}${size} · updated ${age(pull.updated_at, now)}.${detail}`;
    }).join('\n')
    : 'No open pull requests.';

  const blockers = [
    ...blockedPulls.map((pull) => `- PR ${prLink(owner, repo, pull.number)}: ${sentence(pull.blockers.join('; '))}`),
    ...blockerIssues.map((issue) => `- Issue ${issueLink(owner, repo, issue.number)}: ${sentence(issue.title)}`),
  ];

  const recorded = merged.length
    ? merged.map((pull) => `- ${prLink(owner, repo, pull.number)}: ${sentence(pull.summary)}`).join('\n')
    : 'No new merged decision records in this window.';
  const pending = decisions.length
    ? decisions.map((issue) => `- Issue ${issueLink(owner, repo, issue.number)}: ${sentence(bodySummary(issue.body, issue.title))}`).join('\n')
    : 'No open issue is explicitly marked or structured as a decision/proposal.';

  const milestoneText = milestones.length
    ? `${milestones.map((milestone) => {
      const total = milestone.open_issues + milestone.closed_issues;
      const due = milestone.due_on ? ` · due ${shortDate(milestone.due_on, timeZone)}` : '';
      return `- [${inline(milestone.title)}](${milestone.html_url}) — ${milestone.closed_issues}/${total} items complete${due}.`;
    }).join('\n')}\n\n**Immediate execution order**\n\n${inferredSteps(openPulls, openIssues, owner, repo)}`
    : `**Inferred from active work; no open GitHub milestone exists**\n\n${inferredSteps(openPulls, openIssues, owner, repo)}`;

  return [
    `## Weekly state — ${fullDate(now, timeZone)}`,
    '',
    `**At a glance:** ${merged.length} merged PR${merged.length === 1 ? '' : 's'} · ${openPulls.length} open PR${openPulls.length === 1 ? '' : 's'} · ${openIssues.length} open issue${openIssues.length === 1 ? '' : 's'} · ${blockedPulls.length} blocked/waiting PR${blockedPulls.length === 1 ? '' : 's'} · ${decisions.length} pending decision/proposal${decisions.length === 1 ? '' : 's'}.`,
    '',
    `**Coverage:** activity after ${dateTime(since, timeZone)}; current state as of ${dateTime(now, timeZone)}.`,
    '', '### Merged work', '', mergedText,
    '', '### Open pull requests', '', pullsText,
    '', '### Blockers and waiting states', '', blockers.length ? blockers.join('\n') : 'No explicit blockers, merge conflicts, requested changes, or blocking checks were detected.',
    '', '### Decisions', '', '**Recorded through merged work**', recorded, '', '**Pending decisions or proposals**', pending,
    '', '### Next milestones', '', milestoneText,
    '', `_Generated from GitHub PRs, reviews/checks, issues, and milestones. [Workflow run](${runUrl})._`,
  ].join('\n');
}

async function createTracker(github, core, owner, repo, body) {
  try {
    return (await github.rest.issues.create({ owner, repo, title: 'Pi/Oppi weekly project state', body, assignees: [owner] })).data;
  } catch (error) {
    core.warning(`Could not assign tracker to @${owner}: ${error.message}`);
    return (await github.rest.issues.create({ owner, repo, title: 'Pi/Oppi weekly project state', body })).data;
  }
}

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const now = new Date();
  const timeZone = process.env.REPORT_TIME_ZONE || 'America/Los_Angeles';
  const today = localDate(now, timeZone);
  const lookback = boundedInt(process.env.REPORT_LOOKBACK_DAYS, 7, 1, 90);
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;

  let tracker = await trackerIssue(github, owner, repo);
  const comments = tracker ? await github.paginate(github.rest.issues.listComments, {
    owner, repo, issue_number: tracker.number, per_page: 100,
  }) : [];
  const sameDay = comments.find((comment) => String(comment.body || '').includes(reportMarker(today)));
  const prior = comments.map((comment) => metadata(comment.body)).filter((value) => value?.generatedAt)
    .sort((a, b) => new Date(b.generatedAt) - new Date(a.generatedAt));

  let since = new Date(now - lookback * DAY);
  const sameDayMeta = metadata(sameDay?.body);
  if (sameDayMeta?.since && !Number.isNaN(new Date(sameDayMeta.since).getTime())) since = new Date(sameDayMeta.since);
  else if (prior[0] && new Date(prior[0].generatedAt) < now) since = new Date(prior[0].generatedAt);

  const sinceDay = since.toISOString().slice(0, 10);
  const [openPullList, openItems, milestones, mergedSearch] = await Promise.all([
    github.paginate(github.rest.pulls.list, { owner, repo, state: 'open', sort: 'updated', direction: 'desc', per_page: 100 }),
    github.paginate(github.rest.issues.listForRepo, { owner, repo, state: 'open', sort: 'updated', direction: 'desc', per_page: 100 }),
    safe(core, 'Milestones', [], () => github.paginate(github.rest.issues.listMilestones, { owner, repo, state: 'open', sort: 'due_on', direction: 'asc', per_page: 100 })),
    safe(core, 'Merged PR search', [], () => github.paginate(github.rest.search.issuesAndPullRequests, { q: `repo:${owner}/${repo} is:pr is:merged merged:>=${sinceDay}`, sort: 'updated', order: 'desc', per_page: 100 })),
  ]);

  const openIssues = openItems.filter((item) => !item.pull_request && item.number !== tracker?.number && !String(item.body || '').includes(TRACKER));
  const openPulls = await mapLimit(openPullList, 6, (pull) => enrichPull(github, core, owner, repo, pull));
  const merged = (await mapLimit(mergedSearch, 6, async (item) => {
    const pull = await safe(core, `Merged PR #${item.number}`, item, async () => (await github.rest.pulls.get({ owner, repo, pull_number: item.number })).data);
    return { ...pull, summary: bodySummary(pull.body, pull.title) };
  })).filter((pull) => pull.merged_at && new Date(pull.merged_at) >= since && new Date(pull.merged_at) <= now)
    .sort((a, b) => new Date(b.merged_at) - new Date(a.merged_at));

  const report = render({ owner, repo, merged, openPulls, openIssues, milestones, since, now, timeZone, runUrl });
  const meta = `${META}${JSON.stringify({ localDate: today, generatedAt: now.toISOString(), since: since.toISOString(), timeZone })} -->`;
  const commentBody = `${reportMarker(today)}\n${meta}\n\n${report}`;
  const trackerBody = `${TRACKER}\n\nThis issue is maintained by the Friday project-state workflow. The body contains the latest report; dated comments preserve weekly history.\n\n${report}`;

  if (!tracker) tracker = await createTracker(github, core, owner, repo, trackerBody);
  else await github.rest.issues.update({ owner, repo, issue_number: tracker.number, state: 'open', body: trackerBody });

  if (sameDay) await github.rest.issues.updateComment({ owner, repo, comment_id: sameDay.id, body: commentBody });
  else await github.rest.issues.createComment({ owner, repo, issue_number: tracker.number, body: commentBody });

  await core.summary.addRaw(report).write();
  core.notice(`Published weekly project state to issue #${tracker.number}.`);
};

module.exports._test = { bodySummary, checkState, closingIssues, localDate, metadata };
