# Teams Cache Meeting Finder

Find today's meeting links when Microsoft Teams or Outlook is down.

The Teams desktop app keeps a local copy of your recent calendar events and invites. This script reads that copy on your own computer and prints today's meetings with their join links. When an invite includes them, it also prints Zoom meeting IDs and passcodes and the organizer's email.

- **Read-only.** It only reads Teams' cache files in your user folder.
- **Offline.** It sends nothing anywhere and saves nothing.
- **No installs** beyond Python 3. It uses only the standard library.

## Run it

### macOS

Open **Terminal** (press `⌘ Space`, type `Terminal`, press Return), paste this and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.py | python3 -
```

To include the next few days, add a number at the end: `| python3 - 3`.

- If macOS asks whether Terminal may access data from other apps, click **Allow**.
- If macOS offers to install the command line developer tools for `python3`, install them and run the command again.

### Windows (not yet tested)

Open **PowerShell** (press Start, type `PowerShell`, press Enter), paste this and press Enter:

```powershell
irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.py | python -
```

If you see "Python was not found", replace `python -` with `py -`, or install Python from [python.org](https://www.python.org/downloads/) and try again.

### If GitHub is unreachable too

Get [`teams_meetings.py`](teams_meetings.py) from a colleague (chat, email or USB stick), open a terminal in the folder where you saved it and run `python3 teams_meetings.py` on macOS or `py teams_meetings.py` on Windows.

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

Below each day's meetings, the script also prints any cached invite emails or meeting messages that mention that date. Use them to check times, or as a fallback when Teams didn't save the event itself.

## What it can and can't do

- It only knows about meetings the Teams desktop app loaded recently, for example ones you saw in the calendar, got a notification for or were invited to. If a meeting is missing, it was never cached on your computer.
- **Teams join links won't work while Teams itself is down.** Zoom, Google Meet and Webex links work as normal.
- Times are shown in your computer's time zone. If a meeting was moved after Teams last synced, the cache still has the old time.
- Organizer and guest emails come from the cached invite, so you can contact them on another channel, such as personal email or phone.
- It works with the new and classic Teams desktop apps on macOS and Windows. Teams in a web browser leaves no cache that this script can read.

## How it works

Teams desktop is a Chromium web app, and it stores its data in IndexedDB, which is a LevelDB database on disk. The script:

1. Finds the Teams IndexedDB folder in these locations:
   - macOS, new Teams: `~/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView/WV2Profile_*/IndexedDB/`
   - macOS, classic Teams: `~/Library/Application Support/Microsoft/Teams/IndexedDB/`
   - Windows, new Teams: `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_*\IndexedDB\`
   - Windows, classic Teams: `%APPDATA%\Microsoft\Teams\IndexedDB\`
2. Reads the LevelDB table files and decompresses them. They use Snappy compression, which the script implements in pure Python.
3. Finds calendar event objects, which are stored in V8 serialization format, and keeps the newest cached version of each event.
4. Searches cached invite emails and meeting messages for the date as a cross-check, and recovers full join links and Zoom passcodes from them.

It only reads the files, and it works whether Teams is running or not.

---

Unofficial tool, not affiliated with Microsoft.
