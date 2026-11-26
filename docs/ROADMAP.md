# QuietSafari roadmap

The early stages are below. What comes after follows the [ad-type catalogue](AD_TYPES.md): close the holes you can already see, then the engine the rest of the types need, and only then more lists. Stability comes first. A rule that can reject the whole file, or hide an article, stays out.

## 1. Scaffold — done

The app opens in Xcode, runs with a free signature, and contains the Safari extensions.

The window has the switch, allowlist, counter, and filter button. The menu bar and launch at login landed with the later settings work.

How to check: the steps in the [README](../README.md). On the test page the red AD blocks are gone and the green paragraph stays.

## 2. Banners and network ads — in the code

The window downloads EasyList and EasyPrivacy, converts them to Safari rules, and serves them from two content blockers. A converted copy is already in the repo, so blocking works before the first download.

Done when:

- Update filters really downloads the lists and shows a date;
- each blocker stays under the safe size and under 150,000 rules;
- ads and privacy are separate blockers, and the allowlist is copied into each;
- uncertain lines are dropped instead of written into the JSON;
- ordinary sites lose typical banners, and the article text stays;
- turning blocking off, or using the allowlist, restores ads after a reload.

## 3. YouTube — in the code

`Extension/Resources/youtube-main.js` runs in the page world at the start of the load and strips ad fields from the player response. `youtube.js` hides banners and seeks a short ad if one still starts. The real video and `googlevideo.com` are not blocked.

Done on youtube.com when:

- the feed and the watch page have no ad slots;
- a pre-roll, and a mid-roll when it can be caught, is skipped;
- a normal video plays, with seeking and sound;
- an allowlisted site, including youtube.com, shows ads again.

`googlevideo.com` and `youtube.com` are still not blocked wholesale.

## 4. Settings window

The everyday window:

- a menu bar icon, so you do not hunt for the Dock icon;
- optional launch at login;
- filter counts and the last update;
- the same switch and allowlist, not a second conflicting panel.

Done when those actions work from the window and the menu bar, and Safari behaves as it does after Update filters.

## 5. Checks

Automated checks for the converter, plus the window: empty allowlist, a bad address, no network during an update, and Safari with the extension still off.

Done when a bad conversion cannot silently empty a blocker, and error text says what to press.

## 6. Signing and distribution

The free path is an ad-hoc Release build from GitHub Actions: zip, disk image, and SHA256, with no paid Apple account. Safari still needs Allow Unsigned Extensions, and it forgets that when it quits.

A paid Developer ID signature and notarization would remove that step. That is not this release.

iPhone is not in these stages. It would reuse the rules and scripts, with a different shared folder and a paid account.

## Next, from the ad-type catalogue

1. **Russian sites.** In the code: QuietSafari Russian, RU AdList (CC BY 3.0, advblock), and rules for `yandex.ru/ads`, `an.yandex.ru`, `yabs.yandex.ru`, Adfox, and `yandex_rtb`. Search, maps, and the home page are not blocked. `mc.yandex.ru` is on the privacy list. Check on a Mac: rifme.net without the ad cards, and `yandex.ru/maps` still opens.
2. **Status row.** If Safari is silent, the row does not stay on “not checked yet”. A real rejection says “error”. An interrupted reload (`SFErrorDomain` error 3) does not.
3. **Scriptlets.** The web extension runs set-constant, json-prune, abort-on-property-read, abort-on-property-write, remove-node-text, prevent-fetch, and prevent-xhr, only with a domain. `abort-current-inline-script` is still dropped.
4. **Procedural cosmetics.** `:has` becomes a page style. `:has-text` and `:upward` run in script. A MutationObserver watches new nodes for about twenty seconds. There is no global “hide any text that says Ad”.
5. **More lists.** RU AdList fits as its own blocker. AdGuard Base and the uBlock unbreak list are not in this build. Cookie notices are a short original list, off until you turn them on.
6. **Regression.** `node scripts/regression.mjs` opens a fixture in headless Chrome, counts visible ad slots, and looks at rifme.net. That is not Safari, and it does not replace watching YouTube and maps yourself.

Out of scope, because there is no safe method: ads stitched into the video on the server, a live stream where the ad is the same flow, ads outside Safari, sponsored articles, and ads on the search page itself.
