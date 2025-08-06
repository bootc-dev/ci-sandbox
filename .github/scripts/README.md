# PR Reviewer Rotation System

This directory contains the automated PR reviewer assignment system that implements the requirements from [issue #1458](https://github.com/bootc-dev/bootc/issues/1458).

## Overview

The system **preserves GitHub's automatic reviewer assignments** (based on CODEOWNERS, last committer, etc.) and **adds the current sprint's primary reviewer** to ensure rotation. This approach ensures that:

- GitHub's intelligent assignments are not overridden
- The sprint rotation system ensures everyone gets review opportunities
- No duplicate assignments occur

## How It Works

1. **Preserve GitHub Assignments**: The system checks existing reviewers assigned by GitHub
2. **Sprint Rotation**: Determines the primary reviewer for the current 3-week sprint
3. **Smart Addition**: Adds the sprint reviewer only if they're not already assigned
4. **No Duplicates**: If the sprint reviewer is already assigned, no action is taken

## Components

### 1. GitHub Actions Workflow (`../workflows/pr-reviewer-rotation.yml`)

- Triggers on PR open, ready_for_review, and synchronize events
- Also triggers on push events to PR branches
- Supports manual dispatch with test mode
- Runs the Python script to add sprint reviewers

### 2. Python Script (`assign_reviewer.py`)

- Reads maintainers from `MAINTAINERS.md`
- Calculates current sprint and primary reviewer
- Preserves existing GitHub assignments
- Adds sprint reviewer only if not already present

### 3. Configuration (`config.json`)

- Configurable sprint duration and start date
- Pool size for each sprint
- Logging level settings

## Sprint Rotation Logic

1. **Maintainer Extraction**: Reads `MAINTAINERS.md` and extracts GitHub usernames
2. **Sprint Calculation**: Calculates current sprint number based on configured start date
3. **Pool Rotation**: Rotates the maintainer list based on sprint number
4. **Primary Selection**: Takes the first person from the rotated pool as the sprint's primary reviewer
5. **Smart Assignment**: Adds the primary reviewer only if not already assigned by GitHub

## Usage

### Automatic Assignment
The workflow runs automatically when:
- A new PR is opened
- A PR is marked as "ready for review"
- Commits are pushed to a PR branch
- Any push to a branch (if it's a PR)

### Manual Testing
```bash
# Test mode (dry run)
python assign_reviewer.py --pr-number 123 --repo owner/repo --test-mode

# Production mode
python assign_reviewer.py --pr-number 123 --repo owner/repo
```

### GitHub Actions Manual Dispatch
Use the GitHub Actions UI to manually trigger the workflow with test mode enabled.

## Configuration

Edit `config.json` to customize:
- Sprint duration (default: 3 weeks)
- Start date for sprint calculation
- Pool size per sprint (default: 3)

## Maintainers File Format

The system reads from `MAINTAINERS.md` and supports these username formats:
- `@username`
- `[username](https://github.com/username)`

## Example Behavior

**Scenario 1**: GitHub assigns `@alice` and `@bob` based on CODEOWNERS
- Sprint reviewer is `@charlie`
- Result: PR gets `@alice`, `@bob`, and `@charlie`

**Scenario 2**: GitHub assigns `@alice` and `@bob` based on CODEOWNERS
- Sprint reviewer is `@alice` (already assigned)
- Result: PR keeps `@alice` and `@bob` (no duplicate)

**Scenario 3**: GitHub assigns no one
- Sprint reviewer is `@charlie`
- Result: PR gets `@charlie`

## Testing

1. Create a test PR in this repository
2. The workflow will automatically run
3. Check the workflow logs to see the assignment process
4. Use test mode to verify without actual assignment

## Troubleshooting

- **No reviewers assigned**: Check `MAINTAINERS.md` format and content
- **Workflow fails**: Verify GitHub token permissions
- **Wrong rotation**: Check sprint start date in config
- **GitHub assignments overridden**: This system preserves GitHub assignments 