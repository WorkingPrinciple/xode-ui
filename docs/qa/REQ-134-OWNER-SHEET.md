# REQ-134 owner observation sheet

For build 624 (`Ode to X Local Candidate.app`). About 25 minutes. Do these after the automated pass
(`tools/qa/req134_run.sh`), with X Ode open and signed in. Write the time and **Pass**, **Fail** or **Skipped**,
plus one line on what you saw. Don't install, uninstall, sign out or play anything. Put any setting you change
back the way it was.

| # | REQ | Do this | Pass when | Result |
|---|---|---|---|---|
| O-10 | 10, 59 | Press Command-F. Type `mortis`. Press Return on Valor Mortis. | The search field takes focus, Valor Mortis appears, Return opens it. | |
| O-11 | 11 | With a game's details open, press Escape. | Details close and the focus ring is back on the same card. | |
| O-12 | 12 | Turn Wi-Fi off. In Library, choose Refresh (or wait for a refresh). Turn Wi-Fi on. | Your games stay on screen with a message and Try Again; Library never looks empty. | |
| O-13 | 13, 17 | Optional, needs Instruments: follow `docs/A11Y-VERIFICATION.md` REQ-13. | Hitches recorded. | |
| O-14 | 14 | On the trackpad, swipe the big hero slowly, quickly, diagonally and back the other way, five times each. | It always lands on the next or previous page, never skips two, and page scrolling still works. | |
| O-15 | 15 | Watch the hero for 20 s. Open Account. Wait 20 s. Close it. Switch to another app for 20 s. | The hero doesn't change behind Account or while X Ode is in the background; a trailer stops. | |
| O-18a | 18 | Without changing settings: click the search field, then press Tab repeatedly through the toolbar, a shelf and a card. Press Return on a card, then Escape. | Every stop shows a ring; Return opens; Escape returns to the card. | |
| O-18b | 18 | Turn on System Settings ▸ Keyboard ▸ Keyboard navigation. Repeat O-18a with Tab and Space. Turn it back off. | Every button is reachable, Space opens, nothing activates twice. | |
| O-19 | 19 | Press Command-F5 (VoiceOver). With Control-Option-Right, walk the toolbar, a Library card, its details, Settings ▸ Permissions and Acknowledgments. Command-F5 to stop. | Every control is read with a name (e.g. "View Hades II, button"); nothing is read only as "button" or "group". | |
| O-20 | 20 | One at a time, turn on Dark appearance, Reduce Motion, Reduce Transparency, Increase Contrast; look at Library and a game's details; turn each back off. | Dark looks right; the hero stops moving with Reduce Motion; bars turn solid with Reduce Transparency; borders get stronger with Increase Contrast. | |
| O-21 | 21 | Run `footprint -p <X Ode PID>` before and after the automated pass. | Memory after is within about 20% of before. | |
| O-93 | 93 | While Library is still loading (just after opening X Ode), open Account and press Escape. | Account closes right away; loading carries on. | |
| O-118 | 118 | Note any macOS permission prompt you saw today, and when. Open Settings ▸ General ▸ Permissions. | No prompt appeared when X Ode opened; the list says when each one is asked. | |
| O-119 | 119 | Only if you're signing in fresh today: watch the first library load. | One "Setting up your library" screen with steps and a count, then the library; no half-drawn window. | |

Notes:
