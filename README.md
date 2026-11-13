# Teams Cache Meeting Finder

Find today's meeting links when Microsoft Teams or Outlook is down.

The Teams desktop app keeps a local copy of your recent calendar events and invites. This tool reads that copy on your own computer and prints today's meetings with their join links. When an invite includes them, it also prints Zoom meeting IDs and passcodes and the organizer's email.

- **Read-only.** It only reads Teams' cache files in your user folder.
- **Offline.** It sends nothing anywhere and saves nothing.
- **Nothing to install.** Copy one line, paste it into a terminal, press Enter.

## Run it (nothing to install)

### macOS

Open **Terminal** (press `⌘ Space`, type `Terminal`, press Return), paste this and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.js | osascript -l JavaScript -
```

This uses the JavaScript engine built into every Mac, so you don't need Python. If macOS asks whether Terminal may access data from other apps, click **Allow**.

To include the next few days, add a number at the end: `| osascript -l JavaScript - 3`.

### Windows (untested)

> **This version hasn't been run on Windows yet.** It may fail with an error. If it does, use the [Python version](#already-have-python) instead, and please let us know what the error said.

Open **PowerShell** (press Start, type `PowerShell`, press Enter), paste this and press Enter:

```powershell
irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.ps1 | iex
```

This uses PowerShell and the C# compiler that come with Windows, so you don't need Python.

To include the next few days:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.ps1))) 3
```

If your company's security settings block it, download [`teams_meetings.ps1`](teams_meetings.ps1), right-click it and choose **Run with PowerShell**, or ask IT. Some managed PCs block PowerShell from compiling code.

## Already have Python?

The same tool also exists as a Python 3 script that uses only the standard library.

macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.py | python3 -
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.py | python -
```

Add a number after the final `-` to include more days, for example `python3 - 3`.

## If GitHub is unreachable too

Get the script for your computer from a colleague (chat, email or USB stick), open a terminal in the folder where you saved it and run it:

| Computer | File | Command |
|---|---|---|
| Mac | [`teams_meetings.js`](teams_meetings.js) | `osascript -l JavaScript teams_meetings.js` |
| Windows | [`teams_meetings.ps1`](teams_meetings.ps1) | `powershell -ExecutionPolicy Bypass -File teams_meetings.ps1` |
| Any, with Python | [`teams_meetings.py`](teams_meetings.py) | `python3 teams_meetings.py` |

## Example output

These meetings are made up:

```
MEETINGS ON FRIDAY 13 NOVEMBER 2026  (times in this computer's time zone)

12:30-13:00  Partner catch-up call
   Organizer : Alex Example
   Your reply: Accepted
   Join link : https://us02web.zoom.us/j/1234567890?pwd=AbCdEf123.1
   Zoom ID   : 123 456 7890   Passcode: x7Ka2q
   Emails seen near this invite: alex@example.com

15:00-15:30  Weekly team sync
   Organizer : Sam Example
   Location  : Microsoft Teams Meeting
   Join link : https://teams.microsoft.com/l/meetup-join/19%3ameeting_...

--- Invites / messages in the cache that mention 13 Nov ---
[1] ...the invite email text, so you can check the time and guests...
```

Below each day's meetings, the tool also prints any cached invite emails or meeting messages that mention that date. Use them to check times, or as a fallback when Teams didn't save the event itself.

## What it can and can't do

- It only knows about meetings the Teams desktop app loaded recently, for example ones you saw in the calendar, got a notification for or were invited to. If a meeting is missing, it was never cached on your computer.
- **Teams join links won't work while Teams itself is down.** Zoom, Google Meet and Webex links work as normal.
- Times are shown in your computer's time zone. If a meeting was moved after Teams last synced, the cache still has the old time.
- Organizer and guest emails come from the cached invite, so you can contact them on another channel, such as personal email or phone.
- It works with the new and classic Teams desktop apps. Teams in a web browser leaves no cache that this tool can read.

**Tested so far:** the macOS (JavaScript) and Python versions, on a Mac with the new Teams app, using both a real cache and a made-up sample cache (see [`tests/`](tests)). **The Windows PowerShell version is untested**, and the Python version hasn't been tried on Windows yet. A GitHub Actions workflow that runs every version on Windows and macOS is included, but it hasn't run yet.

## How it works

Teams desktop is a Chromium web app, and it stores its data in IndexedDB, which is a LevelDB database on disk. Each version of the tool:

1. Finds the Teams IndexedDB folder in these locations:
   - macOS, new Teams: `~/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView/WV2Profile_*/IndexedDB/`
   - macOS, classic Teams: `~/Library/Application Support/Microsoft/Teams/IndexedDB/`
   - Windows, new Teams: `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_*\IndexedDB\`
   - Windows, classic Teams: `%APPDATA%\Microsoft\Teams\IndexedDB\`
2. Reads the LevelDB table files and decompresses them. They use Snappy compression, which the tool implements itself.
3. Finds calendar event objects, which are stored in V8 serialization format, and keeps the newest cached version of each event.
4. Searches cached invite emails and meeting messages for the date as a cross-check, and recovers full join links and Zoom passcodes from them.

It only reads the files, and it works whether Teams is running or not. The three versions, [`teams_meetings.js`](teams_meetings.js) (macOS), [`teams_meetings.ps1`](teams_meetings.ps1) (Windows) and [`teams_meetings.py`](teams_meetings.py) (Python), use the same logic and print the same output.

---

Unofficial tool, not affiliated with Microsoft.
