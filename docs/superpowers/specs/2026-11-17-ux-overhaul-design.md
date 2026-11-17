# CS2 Recorder UX overhaul: design

Goal: first-time setup is one button; every recording is safe and checked automatically; picking frags is fast; the UI matches niitlahti.fi.
The existing `tool/wizard.ps1` stays untouched as a fallback until the new app is verified on a real PC (`START-CLASSIC.bat`).

## Hard rules (from project notes, apply to every component)
- Never delete user files (rename to `*_old_<time>`). Never type or store passwords.
- `-insecure` check while recording stays. Recording on the main Steam account is BLOCKED, not warned.
- Windows PowerShell 5.1 only (no `&&`, no `?:`, no `-AsHashtable`). Files UTF-8; `.ps1` CRLF; `.py` LF.
- Setup engine must run with NO Python installed (it installs Python). So it is PowerShell.
- Downloads are verified (zip starts with `PK`; SHA256 when the source publishes one).
- No commits unless the user asks. Commit identity when asked: `LNiitlahti <20418617+LNiitlahti@users.noreply.github.com>`, no co-author lines.

## Layout (new files only; do not edit `wizard.ps1`)
```
tool/lib/setup.ps1        Checker + fixers + runner          (sub-project 1)
tool/lib/preflight.ps1    pre-recording safety checks        (sub-project 2)
tool/cs2tool.py           + `presets` and `estimate` cmds    (sub-project 3)
tool/app.ps1              local server + launches the window (sub-project 4)
tool/ui/                  index.html, app.css, app.js        (sub-project 4)
tool/tests/               test scripts for each of the above
```

## Contracts

### setup.ps1 (dot-sourceable; also `-Check` / `-Fix <id>` / `-All` CLI that prints JSON)
- `Get-SetupCheck` -> array of `{ id, label, status, detail, fixId }`
  - ids: `csdm`, `postgres`, `postgres_path`, `steam`, `cs2`, `python`, `venv`, `hlae`, `ffmpeg`
  - status: `ok` | `missing` | `fixable` (we can fix automatically) | `manual` (user must act; `detail` says the one action, `fixId` null)
- `Invoke-SetupFix -Id <id> -OnProgress <scriptblock($pct,$msg)>` -> `{ ok, message }`. Idempotent. Rolls back partial downloads.
- `Invoke-SetupAll -OnProgress` -> checks, fixes every `fixable` in dependency order, re-checks; returns final check array.
- Reuse logic already in `wizard.ps1` (Get-CsdmDir, Find-Python, Install-RecTools, Install-Python, Install-Helper, Get-RecToolPaths); port it, do not call into wizard.ps1.
- CSDM missing: `fixable` if it can download the official release installer from the akiver/cs-demo-manager GitHub release and run it silently; otherwise `manual` with the download link.
- PostgreSQL install needs admin + a password: stays `manual` with ONE clear action. `postgres_path` (psql not on PATH) and a stopped service are `fixable` (user PATH edit; Start-Service, elevating only if needed).

### preflight.ps1
- `Get-Preflight -AccountId <id64> -AccountKind <separate|main> -DemoInfo <obj|null>` -> `{ blocking: bool, checks: [{ id, status: ok|warn|block, label, detail }] }`
- checks: `account` (main => block), `cs2_closed` (cs2.exe running => block), `graphics` (reads `cs2_video.txt` of the account; compares known keys against `tool/data/graphics_max.json`; unknown keys never block; missing file => warn), `demo_patch` (14192 => block), `disk_space` (< 20 GB free on output drive => warn), `output_path` (non-ASCII or any of `# % " ' & ^` => block).

### cs2tool.py additions (stdlib + demoparser2 only inside the parsing wrappers; pure logic functions importable without demoparser2 so tests run anywhere)
- `presets --demo D --player SID` -> `{ ok, presets: [{ id, label, kill_ticks: [...] }] }` presets: `all`, `multikills` (rounds with 3+), `aces`, `best_round`, `headshots`, `clutch` (only if derivable, else omit).
- `estimate --clips N --seconds S --fps F --width W --height H --layers a,b,c` -> `{ ok, size_mb, minutes }` (port the numbers from `Get-SizeMb` / `Update-Estimate` in wizard.ps1).

### app.ps1 + ui/
- Starts `System.Net.HttpListener` on `127.0.0.1:<free port>`, serves `ui/`, JSON API under `/api/*`, requires a random per-run token (header `X-Token`, injected into index.html) to stop other local pages calling it.
- Opens the window with Edge/Chrome `--app=<url>` (own profile dir under `data/`), falls back to the default browser. Closing the window stops the server and any child processes it started.
- API: `GET /api/check`, `POST /api/setup/start`, `GET /api/setup/status`, `GET /api/accounts`, `POST /api/preflight`, `POST /api/demo`, `POST /api/kills`, `POST /api/presets`, `POST /api/clips`, `POST /api/estimate`, `POST /api/record/start`, `GET /api/record/status`, `POST /api/record/stop`, `GET /api/report` (zips logs, redacting the user profile name).
- Screens: 1 Setup (one button, one progress bar, items list with status dots) -> 2 Pick (drop demo, player, kills list with preset chips, clip preview, estimate) -> 3 Record (preflight list that must be green, live progress, safety status) -> 4 Done (open folder, RESULT.txt, record more). Errors: plain language + a "Fix it" or "Copy report" button; never raw stack traces.
- Recording logic: port `New-RunFiles`, `Start-Recording`, `Next-RecStep`, `Test-Insecure`, `Finish-Recording` from `wizard.ps1` into `tool/lib/record.ps1` (exposed to app.ps1). Behavior must stay identical (JSON gotchas in project notes: no `#` or `//` inside the JSON, UTF-8 without BOM).

### Styling (niitlahti.fi, dark only)
`--bg:#0a0a0a; --bg-alt:#0d0d0d; --accent:#f97316; --accent-deep:#ea580c; --accent-soft:rgba(249,115,22,.14); --text:#ededed; --muted:#a1a1a1; --faint:#737373; --ok:#4ade80; --err:#f87171`. Radius 14px panels / 10px buttons+tags. Inter for headings (fall back to system sans), mono stack for labels/logs/paths/status. Orange is the only accent; green/red only for status. No serif. Unbranded (no logo), optional small footer "by Lassi Niitlahti". Works offline (no CDN fonts: use system fallbacks; fonts may be embedded later).

## Testing
Pure logic is unit-tested without Windows side effects (mock system calls). Things only verifiable on a real PC (real installs, `-insecure` stop, 3840x2024, UI in Edge) go in `docs/REAL-PC-CHECKLIST.md`.
