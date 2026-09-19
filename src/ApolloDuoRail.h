#import <UIKit/UIKit.h>

// Logos compiles .xm as ObjC++. These helpers are defined in ApolloDuoRail.m
// (C linkage). extern "C" so the C++ callers see _ApolloDuoRailSync rather
// than a mangled name (same convention as ApolloDeviceGeometry.h).

__BEGIN_DECLS

/// YES while the Open Duo leading sidebar is installed and the stock
/// tab bar is hidden. Closed portrait Duo and regular iPhone are NO
/// (stock bottom UITabBar, no side rail).
BOOL ApolloDuoRailIsActive(void);

/// Live Duo mode for the app window: Phone / Closed / Open.
/// Read-only — does not show, hide, or move the rail.
int ApolloDuoCurrentMode(void);

/// YES while My Subreddits is the selected rail item (stock RedditList
/// root). Compact / cover never set this — the rail is hidden there.
BOOL ApolloDuoRailIsPickingSubreddits(void);
void ApolloDuoRailSetPickingSubreddits(BOOL picking);

/// Attach / hide / resize the rail on the main tab controller. Safe on
/// iOS 14 (missing tab-hide selectors are skipped).
void ApolloDuoRailSync(void);

/// Expand a letterboxed stock-nav column to the usable width. Open
/// reserves the leading 120pt column. Closed has no rail (stock tab
/// bar). No midX clamp and no dual-VC hosting.
void ApolloDuoRailFillOpenContent(void);

/// Restore full-bleed frames / insets when the rail hides. Walks every
/// tab nav stack so a leftover leading strip cannot survive Compact
/// / portrait. Also restores preferredContentSize fill hacks.
void ApolloDuoRailClearOpenContent(void);

/// Inset RedditList / ASTableView content so it starts after the rail.
/// Favorite/sub rows get rail clearance only — no wide-row star cluster.
void ApolloDuoRailApplyListInsets(UIScrollView *scrollView);

/// Duo-only: tear down any stale star, bind the current subreddit,
/// refresh filled/outline from Apollo, and reinstall the trailing
/// Auto Layout constraint left of A–Z / clear of the floating rail.
/// Call from cellForRow, willDisplay, and after Open↔Closed. No-op
/// on Phone. No native frame writes.
void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell);

/// Hide the native accessory only (safe from layoutSubviews). Does
/// not install or update Auto Layout.
void ApolloDuoRailHideNativeStarInRow(UITableViewCell *cell);

/// Reinstall custom stars on visible RedditList rows. forceLayout YES
/// also schedules one bounded deferred bind after Open chrome
/// settles. No native-frame re-anchor.
void ApolloDuoRailReanchorSubredditStars(UITableView *tableView, BOOL forceLayout);

/// Reinstall the custom star on every currently visible cell.
void ApolloDuoRailReanchorVisibleStars(UITableView *tableView);

/// Scroll-safe: rebind name / filled state and update the live
/// trailing constant. Does not tear down an already-correct button.
void ApolloDuoRailRefreshVisibleStars(UITableView *tableView);

/// Coalesced next-turn reinstall after table/VC layout.
void ApolloDuoRailReanchorVisibleStarsAfterLayout(UITableView *tableView);

/// Duo RedditList: reinstall custom stars without forcing layout.
void ApolloDuoRailPolishSubredditList(UITableView *tableView);

/// Drop the custom star, its trailing constraint, and the prior
/// subreddit binding. prepareForReuse must call this so reuse
/// cannot inherit a previous cell's frame or Favorite state.
void ApolloDuoRailResetSubredditRowReuse(UITableViewCell *cell);

/// One-shot readable/center margin reset. Not for layoutSubviews.
void ApolloDuoRailPrepareSubredditRow(UITableViewCell *cell);

/// RedditList only: find its table and re-anchor. forceLayout as above.
void ApolloDuoRailReanchorRedditList(UIViewController *controller, BOOL forceLayout);

/// Open: 0 (stock A–Z). Closed has no rail, so this is also 0 at
/// runtime (IsActive is NO).
CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView);

/// Open: no-op (stock A–Z). Closed: no-op (stock tab bar, no rail).
void ApolloDuoRailPinSectionIndex(UITableView *tableView);

/// YES on Compact + dual displays (cover/front). Never YES when the
/// open-inner rail is shown. Ordinary single-screen iPhone is NO.
BOOL ApolloDuoCoverChromeIsActive(void);

/// Nudge the comments jump FAB off Duo's cover pill. Safe for any
/// CommentsViewController-named class; no-ops when cover chrome is off.
void ApolloDuoCoverAdjustJumpButton(UIViewController *comments);

__END_DECLS
