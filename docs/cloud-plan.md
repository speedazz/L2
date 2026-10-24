# Plan: running Stock Watch when the PC is off (DRAFT)

Status: scoping only. Nothing here is built. Items marked **verify** are things I have not confirmed about the cloud service and must be tested before relying on them.

## Why
Today the scans run as local scheduled tasks. They only run while the PC is on and the Claude desktop app is open. A skipped scan is now reported by the next one (health check), but it still can't run while the PC is off.

## What blocks a straight move to the cloud
| Dependency today | Why it breaks in the cloud | Fix |
|---|---|---|
| PowerShell scripts (`fetch-signals.ps1`, `send-telegram.ps1`, `heartbeat.ps1`) | The cloud runtime may be Linux without PowerShell (**verify**) | Port to Python, one file per script, same logic |
| State files in `output/` (seen list, alert log, heartbeat) | A cloud run may start from a clean checkout each time (**verify**) | Store state in the Google Sheet (new "State" tab) or a private branch, not local files |
| Secrets as Windows user environment variables (Telegram token, chat ID, SEC user-agent) | Not available to cloud runs | Store as secrets in the cloud environment settings (**verify** how); never in the repo |
| Google Sheets and Gmail connectors | Cloud sessions may not have the same connectors (**verify**) | If missing: read the sheet through a service account or published CSV, send email through Gmail API credentials, both stored as secrets |
| Network access | Cloud sandboxes may restrict outbound hosts (**verify**) | Allow: api.telegram.org, sec.gov, data.sec.gov, federalregister.gov, news feeds, apewisdom.io, Google News and Bing News RSS, trumpstruth.org |
| Truth Social mirror and other third-party feeds | Cloud IP ranges are sometimes blocked by sites | Test each feed from the cloud before trusting it |

## Options
1. **Claude cloud routine (recommended to test first).** A scheduled cloud agent runs the scan from the GitHub repo. Keeps the AI triage and the email and Telegram writing as they are. Needs the port to Python, state moved to the sheet, and secrets set up.
2. **Small always-on machine** (a spare PC or Raspberry Pi) running the same Windows or Linux scripts and the Claude app. Fewer unknowns, but you maintain hardware and power.
3. **GitHub Actions for fetching, Claude for triage later.** Actions can run the deterministic fetch for free on a schedule, but cannot do the AI triage or write the analysis, so it only gives raw alerts.

## Proposed steps
1. Test one cloud run of a tiny task ("fetch five feeds, send one Telegram line") to answer every **verify** above. No secrets beyond a test Telegram message.
2. Port the three scripts to Python and test them locally against the PowerShell versions.
3. Move state (seen list, alert log, heartbeat) to a "State" tab in the sheet.
4. Create the cloud routine for one slot (the 7:00 AM scan), compare its output with the local one for a few days.
5. Move the other slots, then disable the local tasks.

## Decisions needed from Lionel
- Is storing the Telegram bot token in the cloud environment acceptable? (It lets anyone with access to that environment send as your bot. Regenerate it with @BotFather if it ever leaks.)
- Is it acceptable for repo code and cloud logs to hold only public tickers and no amounts? (That is how the scripts are written today.)
- Keep local tasks as a fallback until the cloud version has run reliably for two weeks?

## Risks
- The cloud service or its terms may change what scheduled agents can do.
- Cloud runs may cost more than local ones (**verify** pricing and usage limits).
- A bug in the port could silently drop alerts; the health check and a side-by-side trial guard against that.
