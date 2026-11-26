# Ad types and what QuietSafari does with them

This is the catalogue of ads you meet in a browser, how each one is delivered, which QuietSafari mechanism can stop it, and the status in this build.

Status is for this branch, not for a wish to match uBlock. The short scriptlet engine and procedural filters are in the web extension. The order of work is in the [roadmap](ROADMAP.md).

| Status | Meaning |
| --- | --- |
| done | A typical case of this kind should disappear in this build |
| partial | Some cases are covered, a noticeable share is not |
| planned | The method is clear and not in the code yet |
| not possible in Safari | There is no separate request or block to remove without breaking the site |
| not our target | This is the site itself, or a legitimate prompt, not someone else’s insert |

## The tools QuietSafari actually has

1. **Network rule** in a content blocker. Safari does not load the address. EasyList, EasyPrivacy, and RU AdList are converted into the three blockers. Page scripts, procedural CSS, and unknown options are dropped rather than written blindly.
2. **Cosmetic rule.** The same blocker hides an element with `display: none`. The selector has to be simple. `:has` in that JSON is not reliable, so procedural forms go to the web extension.
3. **Page script** in the web extension. A short selector list, YouTube, and the named scriptlets.
4. **Response pruning.** `youtube-main.js` strips ad fields from the player JSON before the player reads them.
5. **Allowlist.** A site you add cancels rules inside the content blockers.

Not here: the full uBlock scriptlet set (including abort-current-inline-script), AdGuard filters, and the uBlock unbreak list. Here: RU AdList as its own blocker, Yandex rules, the short scriptlet engine, `:has` / `:has-text` / `:upward`, a MutationObserver for late nodes, and a cookie-notice switch that is off until you turn it on.

Safari’s cap is 150,000 rules per blocker, and a large file can take a long time to compile. Lists are split instead of piled into one file.

## Summary

| Kind | How it arrives | What can stop it | Now |
| --- | --- | --- | --- |
| Ordinary banner | A third-party URL or a known id/class | Network + simple cosmetic | partial |
| Rich media, expanding banner | An ad script draws over the page | Block the script; hide the shell | partial |
| Native card in a feed or article | Markup that looks like the article | Cosmetic on the container; network if a third party loads it | partial |
| “You may like” widgets (Taboola, Outbrain, MGID) | A widget with its own domain | Network + cosmetic | partial |
| Pre-roll, mid-roll, post-roll the player requests (VAST) | A separate request or JSON ad fields | JSON pruning, block the ad SDK, seek a short ad | partial; YouTube is separate |
| Ad stitched into the video on the server (SSAI) | One stream, no separate URL | No safe method | not possible in Safari |
| Outstream, corner, sticky video | A player in a page block | Network on the ad player + cosmetic | partial |
| Companion banner beside a video | A separate block on the watch page | Cosmetic | partial; known YouTube blocks are hidden |
| Popup | `window.open` or a popup load | A popup network rule; a scriptlet if the site opens it | partial |
| Popunder and new-tab ads | A click opens a tab behind | A scriptlet on `window.open` | planned |
| Full-screen interstitial | A layer, often its own script | Cosmetic + scriptlet | partial |
| Sticky header, footer, corner | A fixed block | Cosmetic | partial |
| A prompt to allow notifications, from an ad network | A subscribe script | Block that network | partial |
| A notification macOS already showed | Drawn by the system, not the page | A Safari extension cannot dismiss it | not possible in Safari |
| “Disable your ad blocker” wall | A script checks that the ad is visible | set-constant or abort-on-property-read, only with a domain in the list | partial |
| Ads in Google, Yandex, or Bing search | Part of the search page | Often no third-party URL | not our target on the search page itself |
| That network’s ads on someone else’s site | `yandex.ru/ads`, AdSense | Block the script and the `yandex_rtb` / Adfox container | done for Yandex on other sites; search and maps are left alone |
| Promoted posts on VK, Facebook, Instagram, X, Reddit | The network’s own feed | Cosmetic and a scriptlet for that feed | planned |
| YouTube ads | Player JSON on the same host, sometimes stitched into the file | Strip JSON fields and skip a short ad | partial |
| Twitch, live video with a stitched ad | The ad is the same stream | Same as SSAI | not possible in Safari without breaking the stream |
| Affiliate links and “ad, then the file” redirects | A chain of known trackers | Block the tracker; a scriptlet if the site rewrites the click | partial |
| Cookie and consent prompts | The site’s own layer, or a consent script | A short list, switch off by default | done as a switch, not a full annoyance list |
| Ads inside another app’s browser | Not a Safari window | A Safari extension is not installed there | not possible in Safari |
| A sponsored article | The publisher’s own page | Hiding it would remove the article | not our target |
| Counters and pixels (Metrica, a tracker with no banner) | A small request | EasyPrivacy | partial |
| An ad hiding behind a CNAME | The address looks like the site | A specific subdomain list; blocking the whole site would break it | planned, case by case |

## Banners and networks such as Google

A banner is a rectangle, a top bar, or a sticky side block. It loads from another host (DoubleClick, AdSense, GPT, an exchange) or a script draws it into a predictable node (`ins.adsbygoogle`, `div[id^="div-gpt-ad"]`, `google_ads_iframe`).

EasyList’s network rules are those addresses. A simple cosmetic rule hides the shell if the address never arrived and an empty box remains. That is in this build, so side banners disappear on many sites. It is not every banner: a scriptlet or a `:has` rule never entered the content-blocker file.

The in-app test page is this case: a red `adsbygoogle` block and a request to `googlesyndication.com`.

## Native ads, recommendation widgets, Yandex

A card that looks like an article sits in the feed or between paragraphs. Below the story there is often a “read next” grid from Taboola, Outbrain, MGID, or Revcontent. They have their own domains. EasyList knows many of them, so some of those grids are already blocked on the network.

Yandex’s ad network and Adfox are different. On a page such as rifme.net there is an empty `div id="yandex_rtb_…"`. The script `https://yandex.ru/ads/system/context.js` fills it with cards. The pictures may then load from the advertiser, not from Yandex. Hiding every third-party image would break something useful. Hide the `yandex_rtb` / `adfox` container, and do not load `/ads/`.

RU AdList (advblock, CC BY 3.0) contains `div[id^="yandex_rtb"]` and rules for `an.yandex.ru`. QuietSafari Russian ships that list, plus a few hand-written rules so those containers and hosts are covered even if the list moves.

Search, maps, and the Yandex home page are different. Blocking `yandex.ru` or `ya.ru` wholesale would remove search and maps. Only the ad paths (`/ads/`, `/an/`) and the ad hosts (`an.yandex.ru`, `yabs.yandex.ru`, `adfox.yandex.ru`) are blocked. The Metrica counter `mc.yandex.ru` is not a banner. It belongs on the privacy list. The web extension also hides `yandex_rtb` and `adfox` if the page inserts them after load.

The same split applies to VK and Mail.ru: an ad script and a pixel can be blocked. The whole social network cannot.

## Video

If the player asks for an ad as its own request, or puts the ad in JSON next to the film, that is a client-side insert. It can be stripped from the JSON, or the ad SDK (IMA, VAST) can be blocked. YouTube in this build works that way: `youtube-main.js` removes `adPlacements`, `playerAds`, and `adSlots` before the player starts, and `youtube.js` hides the banners around it and seeks a short ad when the player says one is showing. A normal video longer than three minutes is not seeked because of that. `googlevideo.com` is not blocked: the film arrives from there too.

If the server already joined the ad and the film into one stream (SSAI, some live streams, some Twitch layouts, some streaming plans), the browser receives one address. An extension cannot cut “the ad seconds” out of it without cutting the picture. That is a limit of Safari and of any request blocker. Seeking a short marked segment is only reasonable where the player honestly labels the ad. A live stream often does not.

Video in the article and a sticky player in the corner are usually their own block. Block the player if it is a third party, and hide the container. YouTube’s companion banner uses known tags such as `ytd-companion-slot-renderer`.

## Windows, interstitials, notifications

Safari can mark a popup load. EasyList rules of that kind, when they converted, already block. A popunder the site opens on click and hides behind the current tab is not always a popup load. That needs a scriptlet on `window.open`. It is not in the named set yet.

A full-screen layer and a sticky footer are cosmetic if the block has a stable name. A random class will not be guessed until a filter list adds it.

A “please allow notifications” prompt lives in a page script. If it is a known ad network, that address is blocked. A system notification you already allowed is drawn by macOS. A Safari extension cannot remove it.

## Anti-adblock walls

The site checks that the ad block is not hidden, or that a known variable is not “ads off”, and replaces the article with a wall. The fix is a small script: change the check’s answer, or stop a property from being read. AdGuard and uBlock lists have thousands of `##+js(...)` rules. A Safari content blocker cannot run those. The web extension runs a short named set, only with a domain. `abort-current-inline-script` is still dropped because it breaks sites more often than it removes a wall. The allowlist is the way out if a site breaks.

## Search, feeds, sponsored articles

An ad above Google or Yandex results is the search product. It is drawn by the same page as the real links. Hiding it by the word “Ad” easily hits a real result. QuietSafari does not try. The same network’s script on someone else’s site is a target. See the Yandex section.

A promoted post in VK, Facebook, Instagram, X, or Reddit looks like a normal post. There is no third-party host. It needs cosmetic rules and a scriptlet for that feed, and those go stale with the layout. Planned, without a promise of matching the uBlock app on Firefox.

A sponsored article the publisher ran as a story is the site’s content. It is not hidden.

## Affiliate links

A download button sometimes goes through a chain of other addresses. A known tracker is blocked on the network. If the site rewrites the click in its own script, that needs a scriptlet. Part of this is already covered. The rest is planned.

## Cookies and consent

A “we use cookies” banner is annoying, and it is often a requirement of the site rather than an ad network. QuietSafari has a short list of known banners and a switch that is off by default. A general annoyance list (share buttons, autoplay) is not included. Those lists have different licenses. Check an AdGuard file’s header before shipping it. It is often GPL.

## Where Safari cannot reach

A browser built into another app, mail, or an ad inside a game. QuietSafari lives in Safari on the Mac. Even a “Safari” view inside another app does not receive these rules.

Video with the ad already stitched in on the server is covered above.

## What to do next

The roadmap items for Russian lists, status, scriptlets, procedural filters, the cookie switch, and the regression harness are in this build. On a Mac they still need a look. After that, if sites still work:

1. AdGuard Base and the uBlock unbreak list, only after the license in the file header is checked and the file fits in its own blocker.
2. Do not turn on abort-current-inline-script as a batch. It stops other people’s page code and breaks sites. Use it one site at a time, only if a wall will not come down otherwise.
3. More live pages in `scripts/regression.mjs`. Today it has a fixture and, if the site loads, rifme.net. YouTube and maps are checked in Safari on a Mac, not in that script.

Not on this list, because there is no safe method: SSAI and a stitched live stream, ads outside Safari, a sponsored article, and the ads on the search page itself.
