#!/bin/bash
# save as create-pr.sh

# Variables
BRANCH_NAME="feature/$(date +%Y-%m-%d)-$1"
COMMIT_MSG="$2"
PR_TITLE="$3"
PR_BODY="$4"

# Create branch
git checkout main
git pull
git checkout -b $BRANCH_NAME

# Wait for changes to be made
echo "Make your changes and then press Enter to continue..."
read

# Stage and commit
git add .
git commit -m "$COMMIT_MSG"

# Push
git push -u origin $BRANCH_NAME

# Create PR using GitHub CLI
gh pr create --title "$PR_TITLE" --body "$PR_BODY" --base main