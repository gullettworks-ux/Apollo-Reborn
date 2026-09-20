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

/// Attach / hide / resize the book host. Safe from FillSoon / RailSync
/// (no-op when frames already match).
void ApolloDuoBookSync(void);

/// Re-pin the left-pane content and bring the right host to the front.
/// No-op while a fullscreen media presenter is up, a rotate is in
/// flight, or an apply is already on the stack (hang guard).
void ApolloDuoBookReassertFrames(void);

/// 0 while BookSync / ApplyFrames must not write (media / in-flight).
int ApolloDuoBookShouldApplyFrames(void);

/// If the book split is live and `viewController` is a feed→post
/// comments push, host it on the right and return YES (caller must
/// skip %orig). Otherwise NO.
BOOL ApolloDuoBookAdoptPush(UINavigationController *nav,
                            UIViewController *viewController);

__END_DECLS
