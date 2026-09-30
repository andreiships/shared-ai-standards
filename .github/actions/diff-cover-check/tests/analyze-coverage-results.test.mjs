// Tests for analyze-coverage-results.mjs. Run: node --test .github/actions/diff-cover-check/tests/
// Uses only node:test + a stubbed GitHub client, so it needs no dependencies.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { analyzeCoverageResults } from '../analyze-coverage-results.mjs';

let originalCwd;
let workDir;

// parseCodeowners reads `.github/CODEOWNERS` relative to the cwd. Run from an empty
// temp dir so the result does not depend on whichever repo the test runs in.
before(() => {
  originalCwd = process.cwd();
  workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'diff-cover-check-'));
  process.chdir(workDir);
});

after(() => {
  process.chdir(originalCwd);
  fs.rmSync(workDir, { recursive: true, force: true });
});

function writeReport(percent) {
  const reportPath = path.join(workDir, `diff-cover-${percent}.json`);
  fs.writeFileSync(reportPath, JSON.stringify({
    total_percent_covered: percent,
    total_num_lines: 10,
    total_num_lines_missed: 10 - Math.round(percent / 10),
    src_stats: {},
  }));
  return reportPath;
}

// `payloadLabels` is the frozen event payload; `liveLabels` is what the API returns now.
function makeContext({ payloadLabels = [], prNumber = 7 } = {}) {
  return {
    repo: { owner: 'acme', repo: 'widgets' },
    payload: {
      pull_request: prNumber === null ? undefined : {
        number: prNumber,
        labels: payloadLabels.map(name => ({ name })),
        user: { login: 'author' },
      },
    },
  };
}

function makeGithub({ liveLabels = [], labelError = null } = {}) {
  const calls = [];
  const listLabelsOnIssue = Symbol('listLabelsOnIssue');
  const listReviews = Symbol('listReviews');
  return {
    calls,
    rest: { issues: { listLabelsOnIssue }, pulls: { listReviews } },
    async paginate(route, params) {
      calls.push({ route, params });
      if (route === listLabelsOnIssue) {
        if (labelError) throw labelError;
        return liveLabels.map(name => ({ name }));
      }
      if (route === listReviews) return [];
      throw new Error('unexpected route');
    },
    labelCalls() {
      return calls.filter(c => c.route === listLabelsOnIssue);
    },
  };
}

test('a coverage-override label added after the run started is honoured (read live)', async () => {
  const github = makeGithub({ liveLabels: ['bug', 'coverage-override'] });
  const result = await analyzeCoverageResults({
    reportPath: writeReport(50), threshold: 80, context: makeContext({ payloadLabels: [] }), github,
  });
  // The override path was taken: it now needs CODEOWNERS approval, which this stub does not grant.
  assert.equal(result.shouldFail, true);
  assert.equal(result.reason, 'coverage-override label requires CODEOWNERS approval');
  assert.equal(result.telemetryEvents[0].event, 'coverage_override_without_approval');
  const [call] = github.labelCalls();
  assert.deepEqual(call.params, { owner: 'acme', repo: 'widgets', issue_number: 7, per_page: 100 });
});

test('a label only in the frozen payload is not trusted', async () => {
  const github = makeGithub({ liveLabels: [] });
  const result = await analyzeCoverageResults({
    reportPath: writeReport(50), threshold: 80,
    context: makeContext({ payloadLabels: ['coverage-override'] }), github,
  });
  assert.equal(result.shouldFail, true);
  assert.equal(result.reason, 'Coverage 50% below 80% threshold');
  assert.equal(github.labelCalls().length, 1);
});

test('a PR at or above the threshold makes no label call', async () => {
  const github = makeGithub({ liveLabels: ['coverage-override'] });
  const result = await analyzeCoverageResults({
    reportPath: writeReport(95), threshold: 80, context: makeContext(), github,
  });
  assert.equal(result.shouldFail, false);
  assert.equal(github.calls.length, 0);
});

test('a label API error fails closed (rejects, so the check fails)', async () => {
  const github = makeGithub({ labelError: new Error('HttpError: Resource not accessible by integration') });
  await assert.rejects(
    analyzeCoverageResults({ reportPath: writeReport(50), threshold: 80, context: makeContext(), github }),
    /Resource not accessible/,
  );
});

test('outside a pull_request event there is no label call and the check fails below threshold', async () => {
  const github = makeGithub({ liveLabels: ['coverage-override'] });
  const result = await analyzeCoverageResults({
    reportPath: writeReport(50), threshold: 80, context: makeContext({ prNumber: null }), github,
  });
  assert.equal(result.shouldFail, true);
  assert.equal(result.reason, 'Coverage 50% below 80% threshold');
  assert.equal(github.calls.length, 0);
});
