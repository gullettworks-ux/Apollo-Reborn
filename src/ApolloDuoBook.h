#import <UIKit/UIKit.h>

// Duo book two-pane host. Sibling of the Open rail: feed stays in the
// posts nav, comments live in a detail host on the right. Closed /
// Phone tear the host down and restore stock push. See
// docs/duo-book-layout.md.

__BEGIN_DECLS

/// YES while the right-pane host is installed.
BOOL ApolloDuoBookIsActive(void);

/// Live posture: Phone / Closed / MidOpenBook / FullyOpen.
int ApolloDuoBookCurrentPosture(void);

/// Last hinge status (Unknown when UIHingeInteraction is missing).
int ApolloDuoBookCurrentHingeStatus(void);

/// Attach / hide / resize the book host. Safe from FillSoon. Do not
/// call from viewDidLayout / traitCollectionDidChange — those re-enter
/// every frame during rotate and re-hosted comments (the freeze).
void ApolloDuoBookSync(void);

/// Re-pin the left-pane content and bring the right host to the front.
/// No-op while an overlay, size transition, or apply is in flight.
/// Safe from RailSync layout; never hosts or tears down.
void ApolloDuoBookReassertFrames(void);

/// 0 while BookSync / ApplyFrames / ShowDetail / rail book-fill must
/// not write (overlay, size-class/rotate, or nested apply).
int ApolloDuoBookShouldApplyFrames(void);

/// Pair around viewWillTransition / horizontal size-class change.
/// End debounces until the last in-flight transition settles, then
/// Syncs once. Idempotent.
void ApolloDuoBookBeginSizeTransition(void);
void ApolloDuoBookEndSizeTransition(void);

/// If the book split is live and `viewController` is a feed→post
/// comments push, host it on the right and return YES (caller must
/// skip %orig). Otherwise NO.
BOOL ApolloDuoBookAdoptPush(UINavigationController *nav,
                            UIViewController *viewController);

__END_DECLS
