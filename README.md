# nox 🌙

A beautiful Notion TUI client written in Ruby.

## Features

- 📋 View tasks by status (Kanban-style)
- ⌨️ Vim-style navigation (`h/j/k/l`)
- 🔍 Search tasks
- ✏️ Update task status
- 🎨 Color-coded priorities

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
| `q` | Quit |

## License

MIT
