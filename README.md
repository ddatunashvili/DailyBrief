# DailyBrief

Personal AI daily advisor as a Windows desktop app. Every morning it analyzes what you actually worked on and writes you a daily briefing in Georgian: what got done, what's left, and how to split the day.

Its unit of thought is the **project**, not the folder: a background script builds a registry of your real projects (stack, branch, last commit subjects, uncommitted files, TODO/FIXME left in the code) and every AI run plans from that. Tasks are created per project, linked to the project's folder automatically, and planned into concrete checklists.

Built with [Claude Code](https://claude.com/claude-code).

## Features

- **Daily briefing** — generated each morning by Claude (Sonnet) from activity snapshots, your kanban board, and its own previous state. One page, direct, no generic advice.
- **Project registry** — `core/projects.json`, rebuilt every 30 minutes with no AI: what each project is, what moved in it, what is still open in it. Browsable on the Projects page; one click turns a project into a task.
- **Trello-style kanban** — tasks created by you or by the AI. Drop a folder anywhere in the app to turn it into a task (with confirmation); the folder gets linked and a git-aware scanner baselines it. Tasks that arrive without a folder are auto-linked to the matching project, so they always have evidence to be judged against.
- **Comments are commands** — a comment on a task ("plan it better", "this is done", "split this off") fires a small AI run scoped to that task and its project: the checklist gets rewritten, the status changes, a split-off task appears, and the AI answers you in the thread.
- **Checklist on open** — opening a task that has no plan writes one automatically, once, from the project's real files and commits.
- **Open questions** — when the AI needs a decision it can't derive, it asks on the briefing page and you answer inline; the answer outranks its own observations in the next run.
- **Automatic checks** — every 5 hours (or on demand, per task) a lightweight run compares tasks against real activity: new commits, changed files, dirty state. It appends "what changed" notes to each card and can mark a task done when the evidence is clear. Zero activity → the AI is not invoked at all.
- **Per-task replan** — the AI rewrites a task's plan as concrete checkbox subtasks, respecting your comments.
- **Auto-update** — packaged builds check GitHub releases on launch and every 6 hours, download in the background and install on quit. Settings has a manual check, an install button and switches for every automation.
- **Analytics** — which projects you touch, your active hours, most-changed files. Collected by background PowerShell scripts, no AI involved.
- **AI usage page** — tokens, cost, ETA and a kill switch for every run; open the exact context that was sent to the model as a TXT.
- **Archive** — deleted tasks are archived (recoverable) or hard-deleted; archived tasks are never re-created by the AI.

## Token-diet architecture

The design goal is minimal AI spend:

- Scripts gather and compress everything into a small `check-digest.json`; the model reads only that and returns a tiny `check-patch.json`; scripts apply the patch. The model never touches large files.
- The daily brief is written as a small JSON; a script splices it into the app page.
- Quality-critical runs (daily brief, day replan) use Sonnet; mechanical runs (checks, task replans, publishing) use Haiku.
- Idle checks short-circuit before spawning the model — zero tokens.
- Every run is journaled (duration, tokens, cost) and future runs show a history-based estimate + ETA up front.

## Stack

- **Electron** shell (single window, dark UI, SVG icons, no scrollbars)
- **SQLite** (better-sqlite3) — embedded database, JSON file mirrors for the pipeline
- **PowerShell 5.1** scripts — activity monitor, folder scanner (git-aware), digest builder, patch applier
- **Claude Code CLI** headless (`claude -p` via stdin) — briefs, checks, replans

## Setup

1. `npm install`
2. Adjust the hardcoded base paths in `core/*.ps1` and `main.js` (`ROOT`) to your machine.
3. `npm run build` — builds `output/win-unpacked/DailyBrief.exe` and an NSIS installer. `npm run release` publishes a GitHub release (needs `GH_TOKEN`) that installed copies auto-update from.
4. Optionally register a logon scheduled task pointing at the built exe — the app runs the morning pipeline on start.
5. Requires the Claude Code CLI installed and authenticated (`claude`), and git for repo-aware scanning.

## Privacy

The monitor and snapshots record directory paths, file names and timestamps. The project registry additionally extracts, locally: git branch/commit subjects/`git status`, the first 400 characters of `README.md`, the `package.json` description and dependency names, and TODO/FIXME lines from tracked source files. Only these extracts reach the model — your files are never opened by the AI itself, and nothing is sent anywhere but the model that writes your briefing. All personal data (briefings, board, analytics, registry, database) stays in `core/` and is git-ignored.
