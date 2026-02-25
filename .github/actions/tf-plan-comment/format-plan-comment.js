import fs from 'fs';

/**
 * Determine if a terraform plan should be collapsed.
 *
 * Exported for testing.
 *
 * @param {string} plan - Terraform plan output
 * @returns {object} - { shouldCollapse, hasOnlyUpdates, changedAttrs, hasRealAdditions, hasRealDeletions, hasResourceChanges }
 */
function shouldCollapsePlan(plan) {
  // Detect worker code-only changes (only content_sha256 or content changed)
  //
  // Terraform plan output patterns:
  // - `~ attr = "old" -> "new"` = actual value change
  // - `~ attr = "old" -> (known after apply)` = computed, ignore
  // - `+ attr = (known after apply)` = computed nested value, ignore
  // - `+ attr = "value"` = real addition, DON'T collapse
  // - `- attr = "value"` = real deletion, DON'T collapse
  //
  // We collapse ONLY if:
  // 1. Summary: "Plan: 0 to add, N to change, 0 to destroy"
  // 2. No resource-level changes (created/destroyed/replaced)
  // 3. No real attribute additions/deletions (ignore computed values)
  // 4. All actual value changes are content_sha256 or content

  // Match the plan summary line to extract counts
  const summaryMatch = plan.match(/Plan: (\d+) to add, (\d+) to change, (\d+) to destroy/);
  const hasOnlyUpdates = summaryMatch &&
    summaryMatch[1] === '0' &&  // 0 to add
    summaryMatch[3] === '0' &&  // 0 to destroy
    parseInt(summaryMatch[2]) > 0;  // N to change

  // Match lines with actual before->after changes and extract attribute NAME
  // Pattern: `~ attr_name = value -> new_value` (excludes only computed values)
  // Note: `-> null` is a real change (unsetting config), so we DON'T exclude it
  // Use .* instead of .+ to also capture empty new values like `-> ""`
  // The negative lookahead includes \s* to handle optional whitespace after ->
  const changePattern = /~\s+(\w+)\s*=\s*.+?\s*->\s*(?!\s*\(known after apply\)).*/g;
  const changedAttrs = [];
  let match;
  while ((match = changePattern.exec(plan)) !== null) {
    changedAttrs.push(match[1]);  // Capture group 1 = attribute name only
  }

  // Check for REAL attribute additions/deletions (not computed values)
  // Only checks lines with `attr = value` pattern - list items are harder to distinguish
  // from computed replacements, so we rely on the summary line check instead.
  //
  // Computed (ignore): `+ status = (known after apply)` or `- name = "x" -> null`
  // Real deletion: `- binding = "removed"` (no `->` sequence)
  // Use negative lookahead for `->` to allow `>` in values (e.g., `"must be > 0"`)
  // Exclude lines ending with [ or { (multi-line list/object changes where -> is on later line)
  // The negative lookahead includes \s* to handle optional whitespace before (known after apply)
  const hasRealAdditions = /^\s+\+\s+\w+\s*=\s*(?!\s*\(known after apply\)).+/m.test(plan);
  const hasRealDeletions = /^\s+-\s+\w+\s*=\s*(?!.*->)(?!.*[\[{]\s*$).+$/m.test(plan);

  // Allow content_sha256 and content (both are code-related)
  // Match against the attribute NAME, not the entire line (avoids false matches in values)
  const codeAttrs = new Set(['content_sha256', 'content']);
  const isWorkerCodeOnly = hasOnlyUpdates &&
    !hasRealAdditions &&
    !hasRealDeletions &&
    changedAttrs.length > 0 &&
    changedAttrs.every(attr => codeAttrs.has(attr));

  const hasResourceChanges =
    plan.includes('will be created') ||
    plan.includes('will be destroyed') ||
    plan.includes('must be replaced');

  // Convert null to false for cleaner return values
  const shouldCollapse = !!(isWorkerCodeOnly && !hasResourceChanges);

  return { shouldCollapse, hasOnlyUpdates, changedAttrs, hasRealAdditions, hasRealDeletions, hasResourceChanges };
}

/**
 * Format and post Terraform plan comment to PR.
 *
 * Handles three cases:
 * 1. No changes (exitcode=0): Delete existing comment
 * 2. Changes with collapse enabled: Collapse worker code-only changes
 * 3. Changes without collapse: Show full plan output
 *
 * @param {object} params
 * @param {object} params.github - GitHub API client
 * @param {object} params.context - Action context
 * @param {string} params.planFilePath - Path to terraform plan output file
 * @param {string} params.exitcode - Plan exit code (0=no changes, 1=error, 2=changes)
 * @param {string} params.marker - Unique comment marker for this TF module
 * @param {boolean} params.enableCollapse - Enable worker code-only collapse logic
 * @param {string} params.actor - GitHub actor name
 * @param {string} params.moduleName - Display name for the module (e.g., "cloudflare-workers")
 */
export default async function formatPlanComment({ github, context, planFilePath, exitcode, marker, enableCollapse, actor, moduleName }) {

  // Guard: Only run on pull_request events
  if (!context.issue || !context.issue.number) {
    console.log('Skipping PR comment: not a pull_request event');
    return;
  }

  // Guard: Validate marker to prevent matching all comments
  if (!marker || !marker.trim()) {
    throw new Error('marker is required and cannot be empty');
  }

  // If plan succeeded with no changes, delete any existing comment and exit
  if (exitcode === '0') {
    const comments = await github.paginate(github.rest.issues.listComments, {
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
      per_page: 100,
    });
    const matching = comments.filter(c => c.body.includes(marker));
    for (const comment of matching) {
      await github.rest.issues.deleteComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        comment_id: comment.id,
      });
    }
    return; // No comment needed when plan has no changes
  }

  // Read plan output
  let plan = '';
  try {
    plan = fs.readFileSync(planFilePath, 'utf8');
  } catch (e) {
    plan = 'Error reading plan output. Check workflow logs.';
  }

  const timestamp = new Date().toISOString();
  const collapseResult = enableCollapse ? shouldCollapsePlan(plan) : { shouldCollapse: false };
  const shouldCollapse = collapseResult.shouldCollapse;

  // Build comment body
  let body;
  if (shouldCollapse) {
    body = `${marker}\n#### Terraform Plan (${moduleName})\n\n` +
      `✅ Worker build successful. Code changes will deploy on merge.\n\n` +
      `<details><summary>Plan details</summary>\n\n\`\`\`\n${plan.slice(0, 60000)}\n\`\`\`\n</details>\n\n` +
      `*Updated: ${timestamp} by @${actor}*`;
  } else {
    body = `${marker}\n#### Terraform Plan (${moduleName})\n\n\`\`\`\n${plan.slice(0, 60000)}\n\`\`\`\n\n*Updated: ${timestamp} by @${actor}*`;
  }

  // Find existing comment (paginate to handle PRs with many comments)
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: context.issue.number,
    per_page: 100,
  });
  const existing = comments.find(c => c.body.includes(marker));

  if (existing) {
    await github.rest.issues.updateComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      comment_id: existing.id,
      body: body
    });
  } else {
    await github.rest.issues.createComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
      body: body
    });
  }
}

// Export for testing
export { shouldCollapsePlan };
