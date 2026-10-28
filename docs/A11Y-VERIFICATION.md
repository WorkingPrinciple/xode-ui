# Live verification scripts: input, accessibility, permissions and lifecycle

Source checks (`swift run OdePreview --self-check`, `--settings-check`, `ManagementChecks`) prove the code paths
and rendered states; they are not live acceptance. The steps below are the human-run part. Record for each run:
the installed app build and executable SHA-256, macOS version, the exact settings before and after, and a
screenshot or recording per step. Restore every changed setting afterwards. Do not launch a game, sign in with a
new account, uninstall a healthy install or change global settings unless the run has been allocated for it.

## REQ-13 Scroll responsiveness on a physical trackpad

1. Quit other heavy apps. Open X Ode on Home with a fully loaded library (more than 40 cards).
2. In Instruments, start the **SwiftUI** template with **Hitches** and **Animation Hitches** attached to X Ode.
3. On the physical trackpad, scroll Home and Library: five slow two-finger scrolls top to bottom, five fast
   flicks, then five scrolls while artwork is still loading (first launch after clearing nothing else).
4. Stop. Export the hitch list and the SwiftUI **View Body** and **View Properties** update counts.
5. Pass: no hitch over 33 ms during steady scroll, view-body updates do not grow per frame with scroll offset,
   and the scroll visibly tracks the fingers. Record measured numbers; a synthesized wheel or CPU fixture is not
   a substitute.

## REQ-14 Hero snap on a physical trackpad

Gestures on the Discover/Library hero, each five times: slow drag less than half a page then release; slow drag
more than half a page; quick flick; diagonal swipe (mostly vertical); reversal mid-swipe; swipe at the first and
last page. Pass: each lands on the predicted adjacent page or returns, the page never skips two, vertical page
scroll is not captured by the hero, and keyboard focus does not jump. Keep the current snap policy unless a
recorded gesture fails.

## REQ-17 Performance attribution

Record one Instruments **Animation Hitches** + **Core Animation** + **Metal System Trace** session of 60 s idle on
Home and 60 s of scrolling, once with the default build and once each with a review build that (a) removes the
ambient blur, (b) removes per-card glass, (c) pauses the five-second polling loop. Change only the attributed
cost. If the difference is under measurement noise, record the hypothesis as open.

## REQ-18 Keyboard and Full Keyboard Access

1. Record `defaults read -g AppleKeyboardUIMode` (0 = off). Without changing it, press Tab from the search field
   through the toolbar, Home shelves, Library grid and an open game detail; note every stop and whether a focus
   ring is visible. Return opens a card; Escape closes detail and returns focus to that card.
2. With approval, turn on System Settings ▸ Keyboard ▸ Keyboard navigation (Full Keyboard Access). Repeat: Tab
   and arrow keys reach every button and menu, Space activates, no stop is invisible or doubled, and each card's
   action names the game. Open the card's More menu with Control-Return or VO-Shift-M.
3. Known routed gap (source audit): the Installed shelf artwork button has no Return handler.
4. Restore the setting and record it.

## REQ-19 VoiceOver and contrast on the actual app

1. Start VoiceOver (Command-F5). With VO-Right, walk: sign-in screen (Sign in with Microsoft, the Wine and Ode
   line and the Acknowledgments link), toolbar, Home, a Library card, game detail, Settings ▸ General ▸
   Permissions, Acknowledgments (featured Wine and Ode links), and the Account popup. Each control is announced
   with a name and role; no control is announced only as "button" or "group".
2. Open Accessibility Inspector ▸ Audit on each window and save the report.
3. Take lossless screenshots in light and dark appearance and measure text against its backing with the Digital
   Color Meter; 4.5:1 for body text, 3:1 for text 18 pt and larger.
4. Stop VoiceOver and record that it is off.

## REQ-20 Appearance and accessibility settings

For each of Dark appearance, Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without
Color: record the current value, change it with approval, observe Home, a game detail, the first-load screen and
the hero, then restore. Pass: the hero does not auto-advance under Reduce Motion, materials become opaque under
Reduce Transparency, borders strengthen under Increase Contrast and no status is shown by colour alone.

## REQ-118 Permission prompts on a fresh install

On a Mac or user account that has never run X Ode: open the app and confirm no prompt appears at launch. Then,
one at a time: Settings ▸ Account ▸ Find consoles (X Ode explains, then macOS asks for Local Network); choose a
game folder in Documents or on an external drive (macOS may ask for Files and Folders); finish the first install
(X Ode explains, then macOS asks for Notifications; choose Don't Allow and confirm Settings ▸ Permissions says
notifications are off); sign in (Keychain). Record each prompt's wording. Rename or update the app and confirm the
grants and saved sign-in survive.

## REQ-41, REQ-45 Lifecycle truth

On an allocated exact test title: install, launch, quit the game, Remove from Library (Keep Files) and confirm the
folder remains, add it back, Uninstall and confirm the folder is gone and saves remain, reinstall and launch.
Separately run Repair and, when one is offered, Update; the status line must read Repairing/Updating while it runs
and the result must match the backend job result.

## REQ-49 First run and saved account

Cancel sign-in at the Microsoft page (app returns to sign-in with no error banner left over); disconnect the
network and sign in (failure explains and can be retried); quit and reopen with a saved account (opens signed in
without a prompt); sign out and confirm no account name, avatar or library remains on screen.

## REQ-51, REQ-93, REQ-94 Regression and management transport

Open and close Downloads, Account, Settings, Import and every menu, then quit normally with Command-Q while a
background library load is running. The Account popup must close with Close and with Escape while loading. Quit
must not need force-termination. Keep the app open on Library for ten minutes of background refresh and confirm
no "disconnected" or overload message appears.
