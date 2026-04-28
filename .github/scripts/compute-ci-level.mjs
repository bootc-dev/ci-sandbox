#!/usr/bin/env node
// compute-ci-level.mjs
//
// Determines what CI jobs to run based on event context. For merge_group events,
// queries the GitHub GraphQL API to detect whether this entry is the tip of the
// queue batch. Only the tip runs expensive jobs; earlier entries run cheap checks
// and wait for ALLGREEN to fire.
//
// Outputs (via GITHUB_OUTPUT):
//   run_heavy            - "true" | "false"
//   reason               - human-readable explanation
//   package_os_matrix    - JSON array of OS names
//   integration_os_matrix
//   upgrade_os_matrix
//
// Usage: node compute-ci-level.mjs
// Required env: GITHUB_OUTPUT, GITHUB_SHA, GITHUB_REPOSITORY,
//               GITHUB_EVENT_NAME, GH_TOKEN (for merge_group),
//               MERGE_BASE_REF (for merge_group, set from github.event.merge_group.base_ref)
//               LABELS_JSON (JSON array of PR label names, for pull_request events)

import { appendFileSync } from "node:fs";

// ── OS matrices ───────────────────────────────────────────────────────────────

const FULL = {
  package: ["fedora-43", "fedora-44", "fedora-45", "centos-9", "centos-10"],
  integration: ["fedora-43", "fedora-44", "centos-9", "centos-10"],
  upgrade: ["fedora-43", "centos-10"],
};

const TIER1 = {
  package: ["centos-10"],
  integration: ["centos-10"],
  upgrade: ["centos-10"],
};

const EMPTY = {
  package: [],
  integration: [],
  upgrade: [],
};

// ── Output helpers ────────────────────────────────────────────────────────────

function setOutputs(runHeavy, matrices, reason) {
  const out = process.env.GITHUB_OUTPUT;
  const summary = process.env.GITHUB_STEP_SUMMARY;
  const lines = [
    `run_heavy=${runHeavy}`,
    `reason=${reason}`,
    `package_os_matrix=${JSON.stringify(matrices.package)}`,
    `integration_os_matrix=${JSON.stringify(matrices.integration)}`,
    `upgrade_os_matrix=${JSON.stringify(matrices.upgrade)}`,
  ];
  for (const line of lines) {
    console.log(`  [output] ${line}`);
    if (out) appendFileSync(out, line + "\n");
  }
  if (summary) {
    appendFileSync(summary, `**CI level:** \`${reason}\` (run_heavy=${runHeavy})\n`);
  }
}

function setSummaryTable(sha, tipOid, isTip) {
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (!summary) return;
  const tipLabel = isTip === null
    ? "⚠️ unknown (API failed — defaulted to full suite)"
    : isTip ? "✅ yes — running full suite" : "⏭️ no — skipping expensive jobs";
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
    setOutputs(true, FULL, "forced-full-suite");
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
      setOutputs(true, FULL, "mq-tip-unknown-failsafe");
      return;
    }

    const isTip = tipOid === sha;
    setSummaryTable(sha, tipOid, isTip);

    if (isTip) {
      console.log("This entry IS the queue tip — running full suite");
      setOutputs(true, FULL, "mq-tip");
    } else {
      console.log(`This entry is NOT the queue tip (tip=${tipOid}) — skipping expensive jobs`);
      setOutputs(false, EMPTY, "mq-not-tip");
    }
    return;
  }

  // PR with ci/tier-1 label → tier-1 subset
  if (labels.includes("ci/tier-1")) {
    console.log("Tier-1 suite: ci/tier-1 label");
    setOutputs(true, TIER1, "label-tier-1");
    return;
  }

  // Plain PR → cheap checks only
  console.log("Plain PR — skipping expensive jobs");
  setOutputs(false, EMPTY, "plain-pr");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
