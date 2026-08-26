# IMAX Norcenter cartelera monitor

Watches the movie dropdown for **IMAX Theatre (Norcenter)** on `entradas.todoshowcase.com`
and sends a **Telegram** message when a new movie is added to the cartelera.

Pure `bash` + `curl` (+ `perl`, preinstalled on macOS/Linux). No login, no Python, no browser.

## How it works
The site is ASP.NET WebForms. `monitor.sh` replays the dropdown cascade over HTTP:
`GET page → POST cinema=18`, then parses the movie options (id + title) from the
response. It diffs the ids against `state/known_movies.tsv` and alerts on anything new,
showing the movie titles in the Telegram message.

## Setup
1. **Create a Telegram bot:** message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. **Get your chat id:** message your new bot once, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `result[].message.chat.id`.
3. **Configure:**
   ```sh
   cp .env.example .env
   # edit .env, paste TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID
   ```
4. **Test:**
   ```sh
   ./monitor.sh --test     # just prints current movies, no state/alerts
   ./monitor.sh            # first run = baseline + a "started" Telegram message
   ```

## When it messages you

| Trigger | Message |
|---|---|
| First run | 🎬 "iniciado, siguiendo N películas…" + the full list |
| **New movie appears** | 🎟️ "¡Nueva(s) película(s)!" + the titles + cartelera link |
| Something breaks | ⚠️ "con problemas (fallo #N)" + the reason + host |
| Recovers after breaking | ✅ "recuperado (tras N fallos)" |
| Every run, only with `--verbose` | 💓 "Monitor OK — N películas…" |

**Robustness built in:**
- Failures (network error, HTTP non-200, site markup change, zero movies parsed) are
  caught and alerted — the monitor never breaks *silently*.
- Failure alerts are **throttled**: one on the first failure, then only every
  `ALERT_EVERY` runs (default 12) during a prolonged outage — so you're not spammed.
- A **recovery** message fires once it reads the cartelera again, so silence = healthy.
- State is never touched on a failed run, and new movies are only marked "known" after
  the Telegram alert actually sends — so you can't miss a title to a transient glitch.
- Movies are keyed on the site's numeric id, not the title, so cosmetic title edits
  (typo fixes, formatting) don't fire false alerts.

### Heartbeat / "is it alive?" (`--verbose`)
`--verbose` (or env `HEARTBEAT=1`) sends a 💓 on **every** run — success *and* failure
(throttling disabled). With it on, **silence means it isn't running**.

## Schedule

The included `.github/workflows/monitor.yml` runs on GitHub Actions every 5 minutes and
commits the updated state back to the repo. Add `TELEGRAM_BOT_TOKEN` and
`TELEGRAM_CHAT_ID` as repository secrets and it will start alerting.

**cron (local, alternative)**:
```sh
crontab -e
*/20 * * * * /path/to/IMAX-bot/monitor.sh           >> /path/to/IMAX-bot/monitor.log 2>&1
10   * * * * /path/to/IMAX-bot/monitor.sh --verbose >> /path/to/IMAX-bot/monitor.log 2>&1
```
- Line 1: checks at :00, :20, :40; alerts only on new movies / breakage.
- Line 2: sends one 💓 per hour at :10 — staggered off the 20-min slots so the two jobs
  never race on the shared state file.

**macOS gotchas:** grant `/usr/sbin/cron` **Full Disk Access** (System Settings →
Privacy & Security), and note cron **skips runs while the Mac is asleep** (no catch-up).

## Notes
- Runs anonymously — no login, no credentials for the site, nothing to expire between runs.
- State lives in `state/known_movies.tsv` (gitignored). Delete it to re-baseline.
- Format is `id<TAB>title`, sorted by id. Keying on id means a re-worded title on an
  existing movie does *not* trigger an alert.
- `state/known_movies.tsv.failcount` tracks consecutive failures (drives throttling);
  it's cleared automatically on recovery.
- Exit code `2` = fetch/parse failed; state is left untouched so you never lose history.
- Polling every 5–30 min is plenty and stays polite. Don't hammer it.

## Config reference
| Var | Default | Purpose |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | — | Bot token from @BotFather (required for alerts) |
| `TELEGRAM_CHAT_ID` | — | Your chat/user id (required for alerts) |
| `CINE` | `18` | Target cinema id (18 = IMAX Theatre Norcenter) |
| `ALERT_EVERY` | `12` | During an outage, re-alert every N failed runs |
| `HEARTBEAT` | `0` | Set `1` to force `--verbose` (heartbeat every run) |
| `STATE_FILE` | `./state/known_movies.tsv` | Where known movies are stored |
