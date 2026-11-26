# QuietSafari

An ad blocker for Safari on Mac. Build it in Xcode with a free Apple ID. There is no prebuilt app: Safari rejects an ad-hoc signature and reports each extension as no longer valid.

## Install

macOS 14 or later. Xcode from the App Store. A normal Apple ID is enough. The paid developer program is not required.

The project zip is https://github.com/rubpf/QuietSafari/archive/refs/heads/main.zip (the `main` branch). The site is https://rubpf.github.io/QuietSafari/ after the repository is public and GitHub Pages is enabled.

1. Install Xcode from the App Store.
2. Unzip the download and open `QuietSafari.xcodeproj`.
3. Set your Personal Team (free Apple ID) on all five targets, with Automatically manage signing: QuietSafari, QuietSafariExtension, QuietSafariContentBlocker, QuietSafariPrivacy, QuietSafariRussian. The team must match on all five.
4. Press Run.
5. Safari → Settings → Advanced → Show features for web developers.
6. Develop → Allow Unsigned Extensions.
7. Tick the four extensions: QuietSafari, Content Blocker, Privacy, and Russian. Allow QuietSafari on every website.

Allow Unsigned Extensions turns off every time Safari quits. Turn it on again. A free signing profile also expires after about seven days: press Run again.

The sections below are the same path with the checks and the fixes.

## Build it in Xcode

The app already includes converted EasyList, EasyPrivacy, and RU AdList. Update filters downloads them again. On YouTube a script removes ads from the player response before playback and presses Skip if one still starts. The web extension also runs a short set of list scriptlets and procedural filters such as `:has`. What each ad type uses: [docs/AD_TYPES.md](docs/AD_TYPES.md). How it is built, and what is next: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

EasyList and EasyPrivacy belong to their authors and are CC BY-SA. RU AdList (advblock) is CC BY 3.0. QuietSafari does not rewrite them by hand: it converts the lines Safari can express and drops the rest.

## What you need to build in Xcode

- A Mac with macOS 14 or later.
- Xcode 16 or later from the App Store. On the first launch, wait until Xcode finishes installing extra components.
- A normal Apple ID. The paid developer program is not required.

You do not need to run anything in `scripts`. Open `QuietSafari.xcodeproj`.

## Open and run

1. Clone this folder on the Mac. There is no `.app` to double-click here. Xcode creates the app.
2. Xcode → Settings → Accounts. Add your Apple ID if it is missing. Personal Team is your name with that label.
3. Double-click `QuietSafari.xcodeproj`.
4. If Xcode offers to update project settings, click **Perform Changes**.
5. Next to Run, the menus should say **QuietSafari** and **My Mac**.
6. Click the blue project icon. Under TARGETS, select each of these five and set the same Personal Team with **Automatically manage signing**:
   - QuietSafari
   - QuietSafariExtension
   - QuietSafariContentBlocker
   - QuietSafariPrivacy
   - QuietSafariRussian

   The team must match on all five, or the window and Safari will not share settings.
7. Press Run (Command+R).
8. If Xcode asks for the keychain password, that is your Mac password. Click Always Allow.
9. The QuietSafari window should open.

If Xcode says `com.quietsafari.macos` is already in use, edit `Config/Shared.xcconfig` and change that prefix, then Run again.

## Turn on in Safari

A build from Xcode is unsigned as far as the App Store is concerned. Without the checkboxes below, the extensions do nothing.

1. Safari → Settings → Advanced.
2. Turn on **Show features for web developers**.
3. Develop → **Allow Unsigned Extensions**. macOS asks for your password.
4. Safari → Settings → Extensions.
5. Turn on:
   - **QuietSafari** — YouTube, list scriptlets, and the counter
   - **QuietSafari Content Blocker** — EasyList
   - **QuietSafari Privacy** — EasyPrivacy, including Metrica
   - **QuietSafari Russian** — RU AdList and Yandex ads (RSYA, Adfox)
6. Select QuietSafari and choose **Always Allow on Every Website**.

Quitting Safari turns Allow Unsigned Extensions off. Turn it on again before the next check. A free signing profile also expires after about seven days: press Run again.

After each new Run, Safari may untick the extensions because the signature changed. Open Extensions and turn all four on again.

## Check

The QuietSafari window should be open. All four Safari items are on, and QuietSafari is allowed on every site.

**Status.** Content Blocker, Privacy, and Russian should say “on” soon after you enable them. “updating…” means Safari is still compiling a list. If a row stays on “not checked yet”, it becomes “off” and the window points at the duplicate-extension section below. “on” is also set when Safari has actually asked for the rules.

**Test page.**

1. Click **Open test page**.
2. If macOS asks about incoming connections, click **Allow**. The page only listens on this Mac.
3. The red AD blocks should be gone. The green paragraph should stay.
4. Under each block the page says what hid it. The network line should say the ad address did not load. If the extension script did not run, turn on QuietSafari and allow every website.
5. If 127.0.0.1 is still in the allowlist, the page says so and the red blocks stay. Remove that address and reload.

**A normal site.** Open a news page that used to have side banners. The banners should be gone. The article should stay.

**Yandex ads.** Open https://rifme.net/ after QuietSafari Russian is on.

- The ad cards (dating, cloud, and similar blocks inside `yandex_rtb`) should be gone.
- The page text and the VK comments widget should stay.
- https://yandex.ru/maps and https://ya.ru should still open.

**Cookie notices.** The switch is off, so a cookie banner on a normal site stays. Turn on “Hide cookie notices” and reload to hide known banners (OneTrust, Cookiebot, and a few others). Turn it off again if a site will not continue without that banner.

**YouTube.** Open a video that used to show a Sponsored pre-roll.

- The ad before the video, and in the middle, should not start. The chosen video plays, with sound and seeking.
- Sponsored slots on the home page and beside the video should be hidden.
- If an ad still flashes, it should disappear on its own.
- A normal video shorter than three minutes should play through.

**Allowlist.** Add `127.0.0.1`, reload the test page, and the red blocks come back. Remove it and reload again.

**Fresh lists.** With a network, Update filters downloads EasyList, EasyPrivacy, and RU AdList. The window shows three counts and a date. Without a network, the built-in set remains.

## Menu bar

After Run, a leaf appears in the menu bar. Click it for the blocking switch, the current Safari site (or a typed domain), the counter, the three blockers, Update filters, Open settings, launch at login, and Hide Dock icon. Quit QuietSafari closes the window and the icon.

The app icon is a white leaf on a muted sage rounded square. Source: `App/AppIcon.svg`.

## Two copies of one extension

This happens after a new Run if an old QuietSafari build is still on disk. Safari → Settings → Extensions then shows two rows with the same name. The checkbox is on the old one, and the new app says “not checked yet” or “off”.

1. Quit Safari completely.
2. In Finder, Go → Go to Folder, and paste:

   `~/Library/Developer/Xcode/DerivedData`

3. Delete every folder whose name starts with `QuietSafari-`. Those are old Xcode builds, not this project.
4. If you copied `QuietSafari.app` to Applications or the desktop, delete that copy too.
5. Press Run. In Safari → Settings → Extensions, each name should appear once. Turn those on and allow QuietSafari on every website again.

## If something goes wrong

**The window did not open, and Xcode is red about App Groups.**  
A free team sometimes fails on the shared folder. Blocking from the built-in list can still work. In each of these files, delete the `com.apple.security.application-groups` key and the array under it:

- `App/QuietSafari.entitlements`
- `Extension/QuietSafariExtension.entitlements`
- `ContentBlocker/QuietSafariContentBlocker.entitlements`

Press Run again. The switch and allowlist work only after the shared folder signs. The test page and built-in rules work without it.

**The window says the shared folder is unavailable.**  
All five targets need a Team, not None and not Sign to Run Locally without a team. Use the same team, then Run again.

**Safari shows no extensions.**  
Open the app with Run at least once. Quit Safari and open it again. Check Develop → Allow Unsigned Extensions.

**Extensions are there, but the red blocks remain.**  
All four are on, including QuietSafari Russian. QuietSafari is allowed on every website. The page was reloaded after that. Allow Unsigned Extensions is on for this Safari launch.

**A content blocker says “error” while its Safari checkbox is on.**  
The line under the row is Safari’s reason, and only when the rule list was rejected. “updating…” means Safari is still accepting the lists one at a time. SFErrorDomain error 3 (loading interrupted) is not shown as an error: the previous rules stay. A checkbox only means the extension is enabled.

**Red blocks on the test page while everything says on.**  
Read the lines under the blocks. “127.0.0.1 is allowed” means remove that address. “script did not run” means QuietSafari is off or not allowed on every website. “The ad script loaded” means the Content Blocker network rules were not applied: read the status error.

**Update filters says an extension did not accept the rules.**  
Turn on Content Blocker, Privacy, and Russian in Safari, then press the button again. Built-in lists are also picked up when you enable the extension, without the button.

**Xcode keeps asking for the password.**  
Click Always Allow, not Allow once.

For more detail, open Console, search for `QuietSafari`, and repeat the action.

## Not in this version

- An ad YouTube stitches into the video file itself can flash. It cannot be removed from the URL without breaking the video. The script seeks past it.
- A paid signature for install without the unsigned-extension step.

The order of work is in [docs/ROADMAP.md](docs/ROADMAP.md).
