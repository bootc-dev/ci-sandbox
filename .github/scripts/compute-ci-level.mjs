#!/usr/bin/env node
// compute-ci-level.mjs
//
// Determines what CI jobs to run based on event context. For merge_group events,
// queries the GitHub GraphQL API to detect whether this entry is the tip of the
// queue batch. Only the tip runs the full deep matrix; earlier entries run only
// tier-0 cheap checks and wait for ALLGREEN to fire.
//
// Three levels:
//   tier-0  cheap checks (fmt, build sanity) — always runs
//   tier-1  basic OS matrix + light integration tests — merge queue, labeled PRs
//   tier-2  full deep matrix — merge queue tip only (or forced)
//
// Outputs (via GITHUB_OUTPUT):
//   ci_level             - "tier-0" | "tier-1" | "tier-2"
//   reason               - human-readable explanation
//   build_os_matrix      - JSON array of OS names (tier-1+)
//   integration_os_matrix - JSON array of OS names (tier-2 only)
//
// Usage: node compute-ci-level.mjs
// Required env: GITHUB_OUTPUT, GITHUB_SHA, GITHUB_REPOSITORY,
//               GITHUB_EVENT_NAME, GH_TOKEN (for merge_group),
//               MERGE_BASE_REF (for merge_group, set from github.event.merge_group.base_ref)
//               LABELS_JSON (JSON array of PR label names, for pull_request events)

import { appendFileSync } from "node:fs";

// ── OS matrices ───────────────────────────────────────────────────────────────

// Tier-1: a representative subset, fast feedback
const TIER1 = {
  build: ["ubuntu-24.04", "fedora-44"],
  integration: [],
};

// Tier-2: full matrix run at merge queue tip
const TIER2 = {
  build: ["ubuntu-24.04", "fedora-44"],
  integration: ["ubuntu-24.04", "fedora-44"],
};

// Tier-0: nothing beyond the cheap jobs themselves
const TIER0 = {
  build: [],
  integration: [],
};

// ── Output helpers ────────────────────────────────────────────────────────────

function setOutputs(level, matrices, reason) {
  const out = process.env.GITHUB_OUTPUT;
  const summary = process.env.GITHUB_STEP_SUMMARY;
  const lines = [
    `ci_level=${level}`,
    `reason=${reason}`,
    `build_os_matrix=${JSON.stringify(matrices.build)}`,
    `integration_os_matrix=${JSON.stringify(matrices.integration)}`,
  ];
  for (const line of lines) {
    console.log(`  [output] ${line}`);
    if (out) appendFileSync(out, line + "\n");
  }
  if (summary) {
    appendFileSync(summary, `**CI level:** \`${level}\` (${reason})\n`);
  }
}

function setSummaryTable(sha, tipOid, isTip) {
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (!summary) return;
  const tipLabel = isTip === null
    ? "⚠️ unknown (API failed — defaulted to full suite)"
    : isTip ? "✅ yes — running full suite" : "⏭️ no — running tier-1 subset";
  appendFileSync(summary, [
    "",
    "### Merge Queue Position",
    "| | |",
    "|---|---|",
    `| This SHA | \`${sha}\` |`,
    `| Queue tip | \`${tipOid ?? "unknown"}\` |`,
    `| Is tip | ${tipLabel} |`,
    "",
  ].join("\n"));
}

// ── Queue tip detection ───────────────────────────────────────────────────────

async function fetchQueueTip(owner, repo, branch) {
  const query = `
    query($owner: String!, $repo: String!, $branch: String!) {
      repository(owner: $owner, name: $repo) {
        mergeQueue(branch: $branch) {
          entries(last: 1) {
            nodes { headCommit { oid } }
          }
        }
      }
    }
  `;

  const response = await fetch("https://api.github.com/graphql", {
    method: "POST",
    headers: {
      Authorization: `bearer ${process.env.GH_TOKEN}`,
      "Content-Type": "application/json",
      "User-Agent": "compute-ci-level",
    },
    body: JSON.stringify({ query, variables: { owner, repo, branch } }),
  });

  if (!response.ok) {
    throw new Error(`GraphQL request failed: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  if (data.errors) {
    throw new Error(`GraphQL errors: ${JSON.stringify(data.errors)}`);
  }

  const nodes = data?.data?.repository?.mergeQueue?.entries?.nodes;
  if (!Array.isArray(nodes) || nodes.length === 0) {
    throw new Error("Empty or missing mergeQueue entries in response");
  }

  return nodes[0].headCommit.oid;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const event = process.env.GITHUB_EVENT_NAME;
  const sha = process.env.GITHUB_SHA;
  const repo = process.env.GITHUB_REPOSITORY; // "owner/name"
  const [owner, repoName] = repo.split("/");
  const labelsJson = process.env.LABELS_JSON ?? "[]";
  const labels = JSON.parse(labelsJson);

  console.log(`Event: ${event}`);
  console.log(`SHA: ${sha}`);

  // workflow_dispatch or ci/merge label → always full suite
  if (event === "workflow_dispatch" || labels.includes("ci/merge")) {
    console.log("Full suite: forced by event or label");
    setOutputs("tier-2", TIER2, "forced-full-suite");
    return;
  }

  if (event === "merge_group") {
    // Extract branch from MERGE_BASE_REF env var (set from
    // github.event.merge_group.base_ref in the workflow YAML).
    const baseRef = process.env.MERGE_BASE_REF ?? "refs/heads/main";
    const branch = baseRef.replace(/^refs\/heads\//, "");

    console.log(`Merge queue event — detecting tip for branch: ${branch}`);

    let tipOid;
    try {
      tipOid = await fetchQueueTip(owner, repoName, branch);
      console.log(`Queue tip OID: ${tipOid}`);
    } catch (err) {
      console.warn(`WARNING: Failed to fetch queue tip: ${err.message}`);
      console.warn("Defaulting to full suite (fail-safe)");
      setSummaryTable(sha, null, null);
      setOutputs("tier-2", TIER2, "mq-tip-unknown-failsafe");
      return;
    }

    const isTip = tipOid === sha;
    setSummaryTable(sha, tipOid, isTip);

    if (isTip) {
      console.log("This entry IS the queue tip — running full suite");
      setOutputs("tier-2", TIER2, "mq-tip");
    } else {
      console.log(`This entry is NOT the queue tip (tip=${tipOid}) — cheap checks only`);
      setOutputs("tier-0", TIER0, "mq-not-tip");
    }
    return;
  }

  // PR with ci/tier-1 label → tier-1 subset
  if (labels.includes("ci/tier-1")) {
    console.log("Tier-1 suite: ci/tier-1 label");
    setOutputs("tier-1", TIER1, "label-tier-1");
    return;
  }

  // Plain PR → cheap checks only
  console.log("Plain PR — tier-0 only");
  setOutputs("tier-0", TIER0, "plain-pr");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
