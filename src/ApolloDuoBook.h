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

/// Secondary navigation from the hosted comments pane: push onto the
/// detail nav (never the posts/feed nav). Feed→comments still uses
/// AdoptPush / ShowDetail. Media overlays return NO (stock present).
BOOL ApolloDuoBookAdoptShow(UIViewController *source,
                            UIViewController *destination);

/// Strip comments/media off a posts-nav `setViewControllers:` stack
/// and re-host the last comments on the right. Returns the stack to
/// install (same pointer when nothing was stolen).
NSArray *ApolloDuoBookAdoptPostsStack(UINavigationController *nav,
                                      NSArray *controllers);

/// If comments were stolen onto the posts nav (in-post tap / media
/// dismiss), move them back to the right host. Safe to call often.
void ApolloDuoBookRecoverIfNeeded(void);

/// Keep a working back chevron on hosted detail pages. No-op when
/// `controller` is not in the right-pane nav.
void ApolloDuoBookEnsureDetailBack(UIViewController *controller);

/// YES when the live canvas should show the V1 Open *leading* rail
/// alongside the book split (including ~951pt Phone-mode Duo sim).
/// The rail is visual only on top of book frames — it must not add
/// a second left chrome inset.
int ApolloDuoBookWantsOpenRail(void);

__END_DECLS
