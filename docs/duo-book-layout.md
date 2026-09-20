# Duo book / two-pane layout

First-slice **feed | comments** layout for iPhone Duo. The frozen
`release/apollo-duo-v1` chrome is unchanged: Closed portrait Duo keeps
the stock bottom tab bar, Open Duo keeps the leading rail + Subs
chrome, and regular iPhones stay single-pane.

`ApolloFeedSplitEnabled` stays **NO**. The old Mail-style dual-VC
host inside one `ApolloNavigationController` (column pins from
`viewDidLayout`, `SetPrimaryAlongside`, stack surgery) is what
produced overscroll ghosts and skippy comments scroll. This slice
hosts comments in a **sibling** of the posts nav instead.

V1 Duo code is **copied and adapted** here (rail posts-nav lookup,
`ApolloDuoCurrentMode`, `ApolloDuoRailFillPaneContent`, Subs chrome,
FeedSplit column math). The frozen `release/apollo-duo-v1` branch /
`apollo-duo-v1` tag / Desktop `ApolloDuoV1-SAFE` artifacts are not
modified.

## When the split is on

| Posture | How it is detected | Split |
| --- | --- | --- |
| **Phone** | `ApolloDuoModePhone` **and** portrait, or landscape without a Duo hint | Never. |
| **Closed** | Portrait-sized Duo window (`ApolloDuoModeClosed`) | Never, unless the hinge is genuinely `partiallyOpen`. |
| **Fully open** | `ApolloDuoModeOpen`, **or** landscape + usable ≥ 652pt + Duo hint (glass / `UIHingeInteraction` / dual display / rail) while V1 still says Phone (Duo sim inner is ~951pt, below the frozen 1000pt wide gate) | Yes, even if `UIHinge.status` is Closed or Unknown. |
| **Mid-open book** | `UIHinge.status == partiallyOpen` on a Duo window | Yes, only when usable width ≥ 652pt (two 320pt columns + gutter). A cover-narrow canvas stays single-pane. |

Detection lives in `src/ApolloDuoBookLayout.h` (`ApolloDuoBookPostureFromCanvas`,
`ApolloDuoBookSplitShouldEnableForCanvas`) and is covered by
`tests/run_duo_book_layout_tests.sh`. The frozen V1
`ApolloDuoWideWindowThreshold` (1000) is not changed.

Runtime hinge install (`src/ApolloDuoBook.m`):

1. Prefer `UIHingeInteraction` on the tab / window (iOS 27.1 Duo API).
   `UIHinge.status` maps 1 / 2 / 3 → closed / partiallyOpen / fullyOpen.
   Out-of-range values are Unknown.
2. Do **not** call `reservedRegions` (SIGSEGV on Duo).
3. Do **not** use hinge **angle** for layout (Apple’s guidance: status +
   size classes, not radians).
4. If the class is missing, hinge stays Unknown and only fully-open
   landscape (`ApolloDuoModeOpen`) enables the split.

Logs (rate-limited): `[DuoBook] sync mode=… hinge=… posture=… usable=… onPostsTab=… want=… why=…`,
`[DuoBook] shown posture=…`,
`[DuoBook] hinge X → Y`,
`[DuoBook] hosted CommentsViewController…`,
`[DuoBook] torn down (closed|phone|narrow|not-posts-tab)`.

## Layout

Left pane = current posts nav (list or feed). Right pane = placeholder
until a post is selected, then that post’s `CommentsViewController`.

Frames reuse `ApolloFeedSplitFramesMake` (balanced, pin-leading) with
Open’s leading-rail extra (120pt). The posts nav stays full-window
(`UITabBarController` resets the selected child’s frame). List/feed
content is pinned to the left half (`FlexibleHeight|FlexibleRightMargin`);
the detail host overlays the right half. The rail stays in front.

Once the posts nav is the left pane, V1 `ApolloDuoRailFillPaneContent`
fills the visible feed/list into `nav.bounds` (no second +120 rail
inset — the pane origin already clears the sidebar). Subs chrome
(`ApolloDuoSubsChromeApply`) then recenters the title / Edit / + on
that left pane. `ApolloDuoRailFillOpenContent` takes the same pane
path while the book is up so Texture / RedditList keep V1 insets.

Tap a later post **replaces** the right pane. Closed / Phone tear-down
unwraps the hosted comments and pushes them onto the posts nav so the
user is not dropped on a blank feed.

## What this slice does not do

Primary path only: **main `PostsViewController` → `CommentsViewController`**.

Not adopted (stock push, or not intercepted):

- `LitePostsViewController`, search results, saved, inbox, profile
  comments, `UserCommentsViewController`
- Swipe-up media comments pane (`ApolloSwipeCommentsIsPaneCommentsController`)
- URL / floating-tab opens that never pass through the posts nav
- list \| feed (Subs directory beside a feed) — Open rail + `popToRoot`
  RedditList is unchanged
- Comments in the right pane sit in a stock `UINavigationController`
  (not the tab’s `ApolloNavigationController`), so some Apollo nav-bar
  chrome / hooks may be missing until a later slice

Wrapping the tab in `UISplitViewController` / `UIArrangementViewController`
is still rejected (settings, floating tabs, swipe-up, URL routing).

## Verify on a Mac (Duo sim)

```bash
tests/run_duo_book_layout_tests.sh
tests/run_duo_compatibility_tests.sh
tests/run_duo_rail_layout_tests.sh
tests/run_feed_split_layout_tests.sh

SIM_NAME="Apollo Duo" \
SIM_DEVICE_TYPE="iPhone Duo" \
SIM_RUNTIME="iOS 27.1" \
./scripts/run-in-sim.sh --glass
```

Expect Open landscape: leading rail, feed on the left, “Select a post”
on the right, then comments on the right after a Home/Popular/All
(or subreddit feed) tap. Fold to Closed: host gone, stock tab bar,
comments on the posts stack if a post was open. Regular iPhone:
no host, no intercept.
