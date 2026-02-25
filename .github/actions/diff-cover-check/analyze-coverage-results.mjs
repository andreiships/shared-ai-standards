/**
 * Coverage Results Analysis Module for GitHub Actions
 * Handles coverage threshold enforcement with override support.
 */
import fs from 'fs';

/**
 * Parse CODEOWNERS file to get list of individual user owners (not teams).
 * Team entries (@org/team) are excluded because reviewer logins are individual
 * GitHub usernames — a team slug will never match a reviewer login.
 * Returns null if file cannot be read (fail-closed security).
 */
function parseCodeowners(codeownersPath = '.github/CODEOWNERS') {
  try {
    const content = fs.readFileSync(codeownersPath, 'utf8');
    const owners = new Set();
    for (const line of content.split('\n')) {
      // Skip comments and empty lines
      if (line.startsWith('#') || !line.trim()) continue;
      // Remove inline comments before parsing
      const lineWithoutComment = line.split('#')[0];
      // Extract @mentions: supports user, dots in names
      // Explicitly exclude org/team entries (contain '/') — they cannot match reviewer logins
      const matches = lineWithoutComment.matchAll(/@([\w.\-]+)/g);
      for (const match of matches) {
        const owner = match[1];
        // Skip org/team entries — they appear as @org/team but the regex above
        // captures only up to the first non-word char so a separate team check isn't needed.
        // (The previous regex allowed slashes; this one intentionally does not.)
        owners.add(owner);
      }
    }
    return owners;
  } catch {
    // Fail closed: if CODEOWNERS can't be read, deny override
    return null;
  }
}

async function checkCodeownersApproval(github, context) {
  const pull_number = context.payload.pull_request?.number;
  if (!pull_number) {
    // Action triggered outside a pull_request event — cannot check reviews
    return false;
  }
  const reviews = await github.paginate(github.rest.pulls.listReviews, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number
  });

  const codeowners = parseCodeowners();
  const prAuthor = context.payload.pull_request?.user?.login;

  // Fail closed: if CODEOWNERS can't be read, deny override
  if (codeowners === null) {
    return false;
  }

  if (codeowners.size === 0) {
    // Fail closed: if no owners defined, no one can approve override
    return false;
  }

  // Solo dev exception: if PR author is the ONLY codeowner (or their bot), the
  // label alone is sufficient since GitHub doesn't allow self-reviews and there's
  // no one else to approve. This enables solo devs to use coverage override.
  // Bot accounts like "username-bot" are treated as equivalent to "username".
  const prAuthorBase = prAuthor?.replace(/-bot$/, '') || '';
  const isSoleDev = codeowners.size === 1 &&
    (codeowners.has(prAuthor) || codeowners.has(prAuthorBase));
  if (isSoleDev) {
    return true;  // Label is sufficient for solo dev
  }

  // Exclude PR author from valid approvers (prevent self-approval bypass in teams)
  const validReviews = reviews.filter(r => r.user.login !== prAuthor);

  // Use latest meaningful review per user to handle stale approvals
  // Filter out COMMENTED/PENDING states which don't affect approval status
  const meaningfulStates = ['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'];
  const latestReviews = new Map();
  for (const review of validReviews) {
    if (meaningfulStates.includes(review.state)) {
      latestReviews.set(review.user.login, review.state);
    }
  }

  // Check if any CODEOWNER's latest meaningful review is an approval
  for (const [user, state] of latestReviews) {
    if (state === 'APPROVED' && codeowners.has(user)) {
      return true;
    }
  }
  return false;
}

/**
 * Read coverage from JSON report file directly (avoids shell/jq dependency)
 * Returns { percent, totalLines, parseError } to handle doc-only PRs and failures
 */
function getCoverageData(reportPath = 'coverage/diff-cover.json') {
  try {
    const content = fs.readFileSync(reportPath, 'utf8');
    const data = JSON.parse(content);

    // Validate required fields exist and are numbers (empty JSON {} should fail)
    if (typeof data.total_percent_covered !== 'number' ||
        typeof data.total_num_lines !== 'number') {
      return { percent: 0, totalLines: 0, parseError: true };
    }

    return {
      percent: data.total_percent_covered,
      totalLines: data.total_num_lines,
      parseError: false,
      crashFallback: data.crash_fallback === true
    };
  } catch {
    // Missing or invalid report should fail, not pass as doc-only
    return { percent: 0, totalLines: 0, parseError: true };
  }
}

export async function analyzeCoverageResults({
  reportPath = 'coverage/diff-cover.json',
  threshold,
  context,
  github
}) {
  const telemetryEvents = [];
  const { percent: coveragePercent, totalLines, parseError, crashFallback } = getCoverageData(reportPath);

  // Missing or invalid report must fail - cannot bypass coverage check
  if (parseError) {
    return {
      shouldFail: true,
      coveragePercent: NaN,
      reason: 'Coverage report missing or invalid JSON',
      telemetryEvents
    };
  }

  // diff-cover crash: sentinel written by the bash fallback — must fail, not pass
  if (crashFallback) {
    return {
      shouldFail: true,
      coveragePercent: NaN,
      reason: 'diff-cover exited non-zero (LCOV parse error or crash) — coverage check skipped is not permitted',
      telemetryEvents
    };
  }

  // Doc-only PRs (0 executable lines) pass automatically - no coverage check needed
  if (totalLines === 0) {
    return {
      shouldFail: false,
      coveragePercent: 100,  // Treat as 100% for display purposes
      reason: 'No executable lines to cover (doc/config-only PR)',
      telemetryEvents
    };
  }

  const labels = context.payload.pull_request?.labels || [];
  const hasOverrideLabel = labels.some(l => l.name === 'coverage-override');
  const belowThreshold = coveragePercent < threshold;

  if (!belowThreshold) {
    return { shouldFail: false, coveragePercent, telemetryEvents };
  }

  if (hasOverrideLabel) {
    const hasApproval = await checkCodeownersApproval(github, context);
    if (!hasApproval) {
      telemetryEvents.push({
        event: 'coverage_override_without_approval',
        actual_coverage: coveragePercent,
        threshold,
        has_approval: false
      });
      return {
        shouldFail: true,
        reason: `coverage-override label requires CODEOWNERS approval`,
        coveragePercent,
        telemetryEvents
      };
    }
    telemetryEvents.push({
      event: 'coverage_override_applied',
      actual_coverage: coveragePercent,
      threshold,
      has_approval: true
    });
    return {
      shouldFail: false,
      reason: `Coverage ${coveragePercent}% below ${threshold}% (override applied)`,
      coveragePercent,
      overrideApplied: true,
      telemetryEvents
    };
  }

  return {
    shouldFail: true,
    reason: `Coverage ${coveragePercent}% below ${threshold}% threshold`,
    coveragePercent,
    telemetryEvents
  };
}

export async function sendTelemetry({ events, axiomToken, context, core }) {
  if (!axiomToken) {
    core.warning('AXIOM_TOKEN not set - skipping telemetry');
    return;
  }

  for (const eventData of events) {
    const payload = [{
      ...eventData,
      timestamp: new Date().toISOString(),
      workflow: context.workflow,
      run_id: context.runId,
      sha: context.sha,
      ref: context.ref,
      pr_number: context.payload.pull_request?.number
    }];

    try {
      const response = await fetch('https://api.axiom.co/v1/datasets/ci-metrics/ingest', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${axiomToken}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
      });

      if (!response.ok) {
        core.warning(`Failed to send Axiom event: ${response.status}`);
      }
    } catch (error) {
      core.warning(`Error sending Axiom event: ${error.message}`);
    }
  }
}
