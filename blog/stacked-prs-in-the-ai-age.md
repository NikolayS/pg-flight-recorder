# Stacked PRs in the AI Age

AI coding assistants can produce pull requests faster than human reviewers can merge them. This creates a practical problem: what do you do when your next piece of work depends on a PR that hasn't been reviewed yet?

## The problem

You have two discrete issues, A and B. B depends on A. With AI assistance you can finish A and start B in the same session, but A's PR is still waiting for review. You have three choices:

1. **Wait.** Branch B from `main` after A merges. This serializes development to the reviewer's pace, which defeats much of the advantage of AI-assisted development.

2. **Stack on the feature branch.** Branch B from A, open B's PR targeting branch A. This looks clean until A merges and GitHub either retargets B automatically (if you delete A's branch) or doesn't (if you forget). When it doesn't, you end up merging B into a stale feature branch instead of `main` and have to recreate the PR.

3. **Stack on main with a draft.** Branch B from A, but open B's PR targeting `main` as a draft. The diff is noisy at first (it shows both A and B changes), but that's cosmetic and temporary. After A merges, rebase B onto `main`, force-push, and undraft. The PR diff is now clean and ready for review.

## The workflow

Option 3 works best. Concretely:

```
git checkout -b feature-a main
# ... do work, commit, push ...
gh pr create --base main --title "Feature A"

git checkout -b feature-b feature-a
# ... do work, commit, push ...
gh pr create --base main --title "Feature B" --draft
```

After feature-a merges:

```
git checkout feature-b
git rebase main
git push --force-with-lease
gh pr ready   # undraft
```

## Why this matters now

The stacking problem isn't new, but AI changes the frequency. A human developer might stack PRs once a sprint. An AI-assisted developer might stack them multiple times a day. Any workflow that serializes on human review throughput leaves AI capacity on the table.

Draft PRs solve this cleanly: development continues at AI pace, reviewers work through the queue at their pace, and the merge target is always `main`.
