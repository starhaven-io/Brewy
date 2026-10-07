import { defineConfig } from "@coderabbitai/config";

// Expand formal review decisions separately from fleet configuration adoption.
const formalReviewRepos = ["homebrew-tap"];

export default defineConfig((ctx) => {
  const pr = ctx.pr;
  const files = pr?.changedFiles;
  const paths = files?.status === "resolved" ? files.paths : [];
  const hasFiles = paths.length > 0;
  const branch = pr?.headBranch ?? "";
  const repo = ctx.repo.name;
  const fleetVersion = /^fleet-(?:sync|release)-v\d{4}\.\d{2}\.\d{2}\.[1-9]\d*$/;
  const cask = branch.match(/^bump-(brewy|macosdb|midden|pinprick)-[0-9][A-Za-z0-9.-]*$/)?.[1];

  // Branch names select a workflow; required GitHub checks verify its output.
  const fleetSync = branch.startsWith("fleet-sync-") && fleetVersion.test(branch);
  const fleetRelease =
    repo === ".github" &&
    branch.startsWith("fleet-release-") &&
    fleetVersion.test(branch) &&
    paths.length === 1 &&
    paths[0] === "fleet/VERSION";
  const caskBump =
    repo === "homebrew-tap" &&
    cask !== undefined &&
    paths.length === 1 &&
    paths[0] === `Casks/${cask}.rb`;
  const catalogUpdate =
    repo === "macOSdb" &&
    /^(?:feat\/data-|fix\/data-rescan-)(?:macOS|Xcode)-[A-Za-z0-9.-]+$/.test(branch) &&
    paths.every((path) =>
      /^data\/(?:macos|xcode)\/(?:releases\.json|releases\/[0-9]+\/[^/]+\.json)$/.test(path),
    );
  const wrapperBump =
    repo === "pinprick-action" &&
    /^chore\/pin-pinprick-[0-9][A-Za-z0-9.-]*$/.test(branch) &&
    paths.every((path) => path === "action.yml" || path === "README.md");
  const dependencyUpdate =
    (pr?.author === "dependabot[bot]" && branch.startsWith("dependabot/")) ||
    (pr?.author === "renovate[bot]" && branch.startsWith("renovate/"));
  const generatedUpdate =
    pr?.author === "starhaven-bot[bot]" &&
    (fleetSync || fleetRelease || caskBump || catalogUpdate || wrapperBump);
  const eligible =
    pr?.author === "p-linnane" || (hasFiles && (dependencyUpdate || generatedUpdate));
  const canApprove =
    ctx.platform === "GitHub" &&
    ctx.repo.owner === "starhaven-io" &&
    formalReviewRepos.includes(repo) &&
    ctx.repo.isPrivate === false &&
    ctx.repo.defaultBranch !== "" &&
    pr?.baseBranch === ctx.repo.defaultBranch &&
    pr?.isDraft === false &&
    eligible;

  return {
    inheritance: false,
    chat: { allow_non_org_members: false },
    reviews: {
      profile: "chill",
      request_changes_workflow: canApprove,
      // The maintainer's exceptional merge path is an approval-only GitHub bypass.
      allow_author_approval: false,
      high_level_summary_in_walkthrough: true,
      review_details: true,
      fail_commit_status: true,
      sequence_diagrams: false,
      estimate_code_review_effort: false,
      related_issues: false,
      related_prs: false,
      suggested_labels: false,
      suggested_reviewers: false,
      poem: false,
      in_progress_fortune: false,
      enable_prompt_for_ai_agents: true,
      auto_review: {
        enabled: true,
        auto_incremental_review: true,
        auto_pause_after_reviewed_commits: 0,
        drafts: false,
        ignore_usernames: [],
      },
      pre_merge_checks: {
        docstrings: { mode: "off" },
      },
      finishing_touches: {
        docstrings: { enabled: false },
        unit_tests: { enabled: false },
        simplify: { enabled: false },
        autofix: { enabled: false },
        fix_ci: { enabled: false },
        resolve_merge_conflict: { enabled: false },
      },
      tools: {
        languagetool: { enabled: false },
      },
    },
  };
});
