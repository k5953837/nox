# nox 🌙

A beautiful Notion TUI client written in Ruby.

## Features

- 📋 View tasks by status (Kanban-style)
- ⌨️ Vim-style navigation (`h/j/k/l`)
- 🔍 Search tasks
- ✏️ Update task status
- 🎨 Color-coded priorities
- 🎯 Workload-aware auto-assign suggestion (`x`)

## Installation

```bash
git clone https://github.com/k5953837/nox.git
cd nox
bundle install
cp .env.example .env
# Edit .env with your Notion token and database ID
```

## Setup

1. Create a Notion integration at https://www.notion.so/my-integrations
2. Share your database with the integration
3. Copy your integration token and database ID to `.env`

## Usage

```bash
./bin/nox
```

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j/↓` | Move down |
| `k/↑` | Move up |
| `h/←` | Previous column |
| `l/→` | Next column |
| `Enter` | View task details |
| `/` | Search |
| `r` | Refresh |
| `x` | Auto-assign suggestion (press `?` in the popup for the metrics) |
| `q` | Quit |

## Auto-assign (派工建議)

Press `x` on a task to get a workload-aware **assignment suggestion** among a
fixed set of owners (Adora Xu / Lin CJ / Galen Lin / Hsiao Jimmy). It scores each
candidate and recommends the highest — **deterministic, no random draw**. Press
`?` inside the popup for an in-app summary; Enter assigns (writes the Notion
`owner`), Esc cancels.

The percentage shown is **relative suitability** — a ranking of the four
candidates for *this* task — not a lottery probability.

### Indicators (all scoped to the current sprint)

| Indicator | Meaning | Source | Normalized to 0–1 |
|-----------|---------|--------|-------------------|
| 可用 Availability (A) | how free they are now | sum of `預估點數` over their open (not Done/Archived) tasks; points on multi-owner tasks are split across co-owners | least-loaded → 1.0, most-loaded → 0.0 |
| 輪替 Rotation (Fr) | how little they've been assigned lately | count of their tasks created in the last 14 days (`Created time` ≈ assignment time) | fewest → 1.0, most → 0.0 |
| 契合 Fit (Ft) | domain experience | overlap of the task's `Fault Domain` / `類型` with their history; **neutral 0.5 for everyone when the task has no tags** | best match → 1.0 |

All three are **relative** (the four candidates compared against each other), not absolute — `A = 1.0` means "the freest of these four," not "completely idle."

### Priority sets the weights

| Priority | A | Fr | Ft | Intent |
|----------|---|----|----|--------|
| `P0` / `P1` (urgent) | 0.5 | 0.1 | 0.4 | give it to someone free and capable; don't spread for fairness |
| `P2` / `P3` / `High` / `Medium` / none | 0.4 | 0.3 | 0.3 | balanced |
| `Low` | 0.3 | 0.5 | 0.2 | not urgent; favor fair rotation |

### How it combines

```
score = wA·A + wFr·Fr + wFt·Ft
%     = softmax(scores)     # the four percentages sum to 100
pick  = argmax(%)           # the highest is recommended (no randomness)
```

Engine: `lib/nox/roulette.rb` (pure, unit-tested). Scope = the current sprint
already loaded in `@board`, so it's instant (no extra Notion fetch).

## License

MIT
