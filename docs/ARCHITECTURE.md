# How QuietSafari is built

This is for the person who runs the app. It is what the blocker is made of, why those Safari pieces were chosen, and what happens when YouTube changes its page.

QuietSafari is a Mac app. It shows a settings window and contains the Safari extensions. Apple requires the extensions to live inside a normal app.

Open the project in Xcode, press Run, and check the test page, a normal site, a YouTube video, and rifme.net. EasyList, EasyPrivacy, and RU AdList are already built in and update from the button. What is next is in the [roadmap](ROADMAP.md).

## What is in Xcode

Five targets:

| Target | What it is | Identifier |
| --- | --- | --- |
| QuietSafari | Settings window | `com.quietsafari.macos` |
| QuietSafariExtension | Safari web extension | `com.quietsafari.macos.extension` |
| QuietSafariContentBlocker | Content blocker, EasyList | `com.quietsafari.macos.content-blocker` |
| QuietSafariPrivacy | Content blocker, EasyPrivacy | `com.quietsafari.macos.privacy` |
| QuietSafariRussian | Content blocker, RU AdList and Yandex | `com.quietsafari.macos.russian` |

Minimum system is macOS 14. No team id is committed. You pick your free Personal Team in Xcode.

## Why more than one extension

Safari blocks ads in two different ways. QuietSafari uses both.

**Content blocker.** You give Safari a rule file. Safari decides which address not to load and which piece of the page to hide. The extension does not see which sites you open. Banners, side slots, ad-network requests, and many trackers are handled here. One file has a hard cap, so ads, privacy, and the Russian list are three blockers.

**Web extension.** Its script runs on the page. YouTube needs it: the ad arrives from the same host as the video. Blocking that host would stop the film. The script reads the player response and skips the ad. The same extension counts what it can see. A content blocker cannot report hits, or it would know where you went.

Safari’s declarativeNetRequest still compiles into the same content-blocker format and the same cap. The reliable base is the JSON Safari compiles itself. The web extension is for YouTube and for rules that JSON cannot express.

In Safari settings you turn on QuietSafari, Content Blocker, Privacy, and Russian.

## How the window talks to Safari

The window writes settings and JSON into a shared folder. The content blocker reads the JSON when Safari asks. The web extension writes only a count, not the page address.

On a Personal Team build the folder is the App Group `TEAMID.com.quietsafari.shared`. Xcode fills in `$(TeamIdentifierPrefix)`. The `group.` prefix is a paid capability, so the free team does not use it. An ad-hoc release has no team id, so that container does not exist. Those builds share `~/Library/Application Support/QuietSafari` instead. All targets of a dev build must use the same team, or each gets a different folder.

What each step does:

1. You flip the switch or add a site. The window writes settings, rebuilds the rule files, and asks Safari to reload them one at a time.
2. The allowlist is `ignore-previous-rules` appended to every blocker. It only cancels rules inside that blocker.
3. Turning blocking off writes `[]`. The extension stays enabled, but there are no rules. Reload open pages.
4. The page script counts hidden elements and tells the app a number. The message does not include the page address.
5. The window rereads the counter and asks Safari whether the extensions are on.
6. If the shared folder is missing, the content blocker still serves the JSON shipped inside it. The test page can work. The switch and allowlist cannot, and the window says so.

Update filters downloads EasyList, EasyPrivacy, and RU AdList, converts them, and asks Safari to reread the three blockers. With no network, the built-in conversion remains.

## Filter lists and Safari’s limits

Three rule files. EasyList is Content Blocker, EasyPrivacy is Privacy, RU AdList plus Yandex rules is Russian. Each stays under about 7 MB and under 150,000 rules. A line that would match a normal YouTube watch page, the Google home page, or Yandex search and maps is dropped.

The window downloads:

- EasyList — `https://easylist.to/easylist/easylist.txt`
- EasyPrivacy — `https://easylist.to/easylist/easyprivacy.txt`
- RU AdList — `https://easylist-downloads.adblockplus.org/advblock.txt`

Those lists use Adblock Plus syntax. Safari does not. The converter keeps what Safari can express. One bad rule can reject the whole file, so uncertain lines are dropped. WebKit’s url-filter cannot use `|`, so the separator is a character class, not an alternation.

Not in the content blocker, and handled by the web extension when they fit the named set:

- page scripts (`##+js`, `#%#//scriptlet`);
- procedural CSS (`:has-text`, `#?#`);
- `removeparam`, `csp`, `redirect`.

Cosmetic exceptions (`#@#`) become `unless-domain` on the hide rule. `if-domain` and `unless-domain` cannot share one rule.

Cookie notices are not a fourth blocker. The web extension hides a short list only when the switch is on.

## YouTube

| What you see | What covers it |
| --- | --- |
| A banner, a feed slot, a masthead | `css-display-none` and the same selectors in the script |
| Skip, and a short ad over the video | The page script seeks only while an ad is actually showing |
| Ads inside the player response | `youtube-main.js` strips the ad fields before the player reads them |

The three-minute cap is a guard. If the player class is wrong and the video is a real one longer than three minutes, the script does not seek it.

Do not block `youtube.com`, `googlevideo.com`, or `ytimg.com` wholesale. The project check rejects a rule that would.

YouTube’s layout lives in `youtube.js` and `youtube-main.js`. When YouTube changes, the edit stays there.

## Settings window

SwiftUI, in English:

- blocking switch;
- a counter that does not pretend to include network blocks;
- an allowlist (`example.com`; `www` is optional);
- Update filters;
- Open test page, on this Mac only (`127.0.0.1`);
- status of the extensions, and whether the shared folder is available;
- a menu bar panel with the same controls, launch at login, and Hide Dock icon.

The test page uses red AD blocks and one request to `googlesyndication.com`, so you can see both hiding and network blocking. macOS may ask once about incoming connections. The server does not listen outside this computer.

## Signing

- In Xcode, the same Personal Team on every target, Automatically manage signing.
- The team id is not committed.
- Builds from Xcode and the ad-hoc release both need Allow Unsigned Extensions. Safari turns that off when it quits.
- A free profile lasts about seven days. Press Run again when the app will not open.
- After a new Run, Safari may disable the extensions because the signature changed.

A downloadable zip without that Safari step needs a paid Developer ID signature and notarization. That is not this release.

## Risks

- YouTube changes its page. The player logic is in two files. An ad stitched into the video file can flash; the script seeks past it and does not block the video URL.
- The 150,000-rule cap and large JSON. Lists are split, and doubtful lines are dropped.
- Some EasyList lines cannot be expressed in Safari. There will not be Firefox-level parity.
- The counter misses network blocks. That is an Apple limit.
- A selector that is too wide can hide part of a site. The converter drops dangerous expressions.
- A free signature expires, and Allow Unsigned Extensions resets. If Run fails on App Groups, the README says which lines to remove.
- Different teams on the targets, or Sign to Run Locally with no team, leave the shared folder empty. The window says so.
- Sites with anti-adblock walls are what the allowlist is for.
- iPhone needs a paid account and a different shared folder. There is no iOS target.

## Where things live

| Path | Why |
| --- | --- |
| `App/` | Window, menu bar, onboarding, test page |
| `Extension/` | Web extension, including YouTube |
| `ContentBlocker/` | EasyList content blocker |
| `Privacy/` | EasyPrivacy |
| `Russian/` | RU AdList and Yandex rules |
| `Shared/` | The three JSON lists |
| `site/` | The public landing page |
| `homebrew-tap/` | The cask to copy into `rubpf/homebrew-tap` |
| `Config/Shared.xcconfig` | Identifiers. Change only if Xcode says they are taken |
| `docs/` | This file, the roadmap, and the ad-type catalogue |
| `scripts/` | Project checks and the ad-hoc release build |
| `QuietSafari.xcodeproj` | What you double-click |
