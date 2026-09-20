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

/// Posts-tab `ApolloNavigationController` when one exists. Does not
/// call `goToHomeTab` (that pops RedditList / races a feed push).
UINavigationController *ApolloDuoRailPostsNavigationController(UITabBarController *tabs);

/// Expand a letterboxed stock-nav column to the usable width. Open
/// reserves the leading 120pt column. Closed has no rail (stock tab
/// bar). No midX clamp and no dual-VC hosting. While the book split
/// is up, fills the top VC into the already-sized left pane (do not
/// apply the 120pt rail frame a second time).
void ApolloDuoRailFillOpenContent(void);

/// Fill `controller` to `container.bounds` and re-apply list insets.
/// Used for the book left pane, whose origin already clears the rail.
void ApolloDuoRailFillPaneContent(UIViewController *controller, UIView *container);

/// Restore full-bleed frames / insets when the rail hides. Walks every
/// tab nav stack so a leftover leading strip cannot survive Compact
/// / portrait. Also restores preferredContentSize fill hacks.
void ApolloDuoRailClearOpenContent(void);

/// Inset RedditList / ASTableView content so it starts after the rail.
/// Favorite/sub rows get rail clearance only — no wide-row star cluster.
void ApolloDuoRailApplyListInsets(UIScrollView *scrollView);

/// No-op. Per-cell readable / centerX / lead-delta thrash hung the Duo
/// sim (25f8a7b) and still left the wrong layout. Releases any leftover
/// constraint claim. Expanded Duo rows are a later patch.
void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell);

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
