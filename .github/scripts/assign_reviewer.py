#!/usr/bin/env python3
"""
PR Reviewer Assignment Script

This script automatically assigns reviewers to pull requests based on a rotating pool
of team members. The rotation is based on 3-week sprint cycles.

Usage:
    python assign_reviewer.py --pr-number <PR_NUMBER> --repo <REPO> [--test-mode]
"""

import argparse
import json
import logging
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Set

import requests

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuration
SPRINT_WEEKS = 3
MAINTAINERS_FILE = "MAINTAINERS.md"
GITHUB_API_BASE = "https://api.github.com"
CONFIG_FILE = ".github/scripts/config.json"


class ReviewerAssigner:
    def __init__(self, repo: str, token: str, test_mode: bool = False):
        self.repo = repo
        self.token = token
        self.test_mode = test_mode
        self.headers = {
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "PR-Reviewer-Rotation"
        }
        self.config = self.load_config()
    
    def load_config(self) -> dict:
        """Load configuration from config file."""
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
            logger.info(f"Loaded config: {config}")
            return config
        except FileNotFoundError:
            logger.warning(f"Config file {CONFIG_FILE} not found, using defaults")
            return {
                "sprint_config": {
                    "weeks_per_sprint": 3,
                    "reviewers_per_pr": 2,
                    "pool_size": 3
                }
            }
        except Exception as e:
            logger.error(f"Error loading config: {e}")
            return {
                "sprint_config": {
                    "weeks_per_sprint": 3,
                    "reviewers_per_pr": 2,
                    "pool_size": 3
                }
            }

    def get_maintainers(self) -> List[str]:
        """Extract maintainers from MAINTAINERS.md file."""
        try:
            with open(MAINTAINERS_FILE, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Extract GitHub usernames from the file
            usernames = set()
            
            # Pattern 1: @username (most reliable)
            at_pattern = r'@([a-zA-Z0-9_-]+)'
            usernames.update(re.findall(at_pattern, content))
            
            # Pattern 2: [username](https://github.com/username)
            link_pattern = r'\[([a-zA-Z0-9_-]+)\]\(https://github\.com/[a-zA-Z0-9_-]+\)'
            usernames.update(re.findall(link_pattern, content))
            
            # Only use @username pattern for now to avoid false positives
            # We can expand this later if needed
            maintainers = list(usernames)
            logger.info(f"Found {len(maintainers)} maintainers: {maintainers}")
            return maintainers
            
        except FileNotFoundError:
            logger.error(f"MAINTAINERS.md file not found")
            return []
        except Exception as e:
            logger.error(f"Error reading MAINTAINERS.md: {e}")
            return []

    def get_sprint_start_date(self) -> datetime:
        """Get the start date of the current sprint."""
        # For testing, we'll use a fixed start date
        # In production, this could be configurable
        sprint_start = datetime(2024, 1, 1)  # Example start date
        return sprint_start

    def get_current_sprint_number(self) -> int:
        """Calculate the current sprint number based on the start date."""
        start_date = self.get_sprint_start_date()
        current_date = datetime.now()
        days_diff = (current_date - start_date).days
        sprint_number = (days_diff // (SPRINT_WEEKS * 7)) + 1
        return sprint_number

    def get_reviewer_pool(self) -> List[str]:
        """Get the current reviewer pool based on sprint rotation."""
        maintainers = self.get_maintainers()
        if not maintainers:
            return []
        
        sprint_number = self.get_current_sprint_number()
        
        # Simple rotation: use sprint number to determine starting index
        start_index = (sprint_number - 1) % len(maintainers)
        
        # Create a rotated list
        rotated_pool = maintainers[start_index:] + maintainers[:start_index]
        
        # Take configured pool size (or all if less than configured size)
        pool_size = min(self.config["sprint_config"]["pool_size"], len(rotated_pool))
        current_pool = rotated_pool[:pool_size]
        
        logger.info(f"Sprint {sprint_number}, Pool: {current_pool}")
        return current_pool

    def get_pr_reviewers(self, pr_number: int) -> Set[str]:
        """Get current reviewers assigned to the PR."""
        url = f"{GITHUB_API_BASE}/repos/{self.repo}/pulls/{pr_number}/requested_reviewers"
        
        try:
            response = requests.get(url, headers=self.headers)
            response.raise_for_status()
            data = response.json()
            
            reviewers = set()
            if 'users' in data:
                reviewers.update(user['login'] for user in data['users'])
            if 'teams' in data:
                # For teams, we'd need to get team members
                # For now, we'll skip teams
                pass
                
            logger.info(f"Current PR reviewers: {reviewers}")
            return reviewers
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error getting PR reviewers: {e}")
            return set()

    def assign_reviewers(self, pr_number: int, reviewers: List[str]) -> bool:
        """Assign reviewers to the PR."""
        if not reviewers:
            logger.warning("No reviewers to assign")
            return False
        
        url = f"{GITHUB_API_BASE}/repos/{self.repo}/pulls/{pr_number}/requested_reviewers"
        data = {"reviewers": reviewers}
        
        if self.test_mode:
            logger.info(f"TEST MODE: Would assign reviewers {reviewers} to PR {pr_number}")
            return True
        
        try:
            response = requests.post(url, headers=self.headers, json=data)
            response.raise_for_status()
            logger.info(f"Successfully assigned reviewers {reviewers} to PR {pr_number}")
            return True
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error assigning reviewers: {e}")
            return False

    def run(self, pr_number: int) -> bool:
        """Main execution function."""
        logger.info(f"Processing PR {pr_number}")
        
        # Get current reviewers (GitHub's automatic assignments)
        current_reviewers = self.get_pr_reviewers(pr_number)
        logger.info(f"Current PR reviewers: {current_reviewers}")
        
        # Get the current sprint's primary reviewer
        reviewer_pool = self.get_reviewer_pool()
        if not reviewer_pool:
            logger.error("No reviewers available in pool")
            return False
        
        # Take the first person from the pool (primary reviewer for this sprint)
        sprint_reviewer = reviewer_pool[0]
        logger.info(f"Sprint primary reviewer: {sprint_reviewer}")
        
        # If the sprint reviewer is already assigned, don't add them again
        if sprint_reviewer in current_reviewers:
            logger.info(f"Sprint reviewer {sprint_reviewer} is already assigned, no action needed")
            return True
        
        # Add the sprint reviewer to the existing reviewers
        reviewers_to_assign = [sprint_reviewer]
        
        return self.assign_reviewers(pr_number, reviewers_to_assign)


def main():
    parser = argparse.ArgumentParser(description="Assign reviewers to PR based on rotation")
    parser.add_argument("--pr-number", type=int, required=True, help="PR number")
    parser.add_argument("--repo", type=str, required=True, help="Repository (owner/repo)")
    parser.add_argument("--test-mode", action="store_true", help="Test mode (dry run)")
    
    args = parser.parse_args()
    
    # Get GitHub token
    token = os.getenv("GITHUB_TOKEN")
    if not token:
        logger.error("GITHUB_TOKEN environment variable not set")
        sys.exit(1)
    
    # Create assigner and run
    assigner = ReviewerAssigner(args.repo, token, args.test_mode)
    success = assigner.run(args.pr_number)
    
    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
