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

/// Duo-only: re-anchor one cell's native star in contentView
/// coordinates after that cell has finished layout. No
/// layoutIfNeeded (safe from layoutSubviews). No-op on Phone.
void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell);

/// Re-anchor visible RedditList stars. forceLayout YES runs the
/// table+cell layoutIfNeeded pass (appear / mode / rotation only).
/// forceLayout NO is scroll / layoutSubviews (frame nudge only).
void ApolloDuoRailReanchorSubredditStars(UITableView *tableView, BOOL forceLayout);

/// Duo RedditList: re-anchor without forcing layout.
void ApolloDuoRailPolishSubredditList(UITableView *tableView);

/// Clear leftover readable/center margins on reuse so a landscape
/// mid-pane column cannot survive into the next mode.
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
