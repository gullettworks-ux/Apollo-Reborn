#import <UIKit/UIKit.h>

// Duo-only Subreddits nav chrome: centered title, Edit (top right),
// floating + wired to Apollo's tappedAddBarButtonItem:. Completes the
// existing rail / Liquid Glass title path — does not retile the list
// or pin a new A–Z overlay. Duo custom stars (Auto Layout, left of
// A–Z and clear of the floating rail) live in
// ApolloDuoRailTightenSubredditRow and are invoked from here so
// Closed Duo still reinstalls them after Open↔Closed without an
// active rail.

__BEGIN_DECLS

/// Install / refresh / restore RedditList chrome for the current Duo
/// mode. No-op on regular iPhone (Phone mode) and on non-RedditList
/// controllers. Safe from viewDidLayoutSubviews: frame writes are
/// guarded and never re-toggle constraints.
void ApolloDuoSubsChromeApply(UIViewController *controller);

/// YES when the visible screen is Apollo's Subreddits list.
BOOL ApolloDuoSubsChromeControllerIsRedditList(UIViewController *controller);

__END_DECLS
