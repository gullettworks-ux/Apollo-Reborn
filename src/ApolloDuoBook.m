#import "ApolloDuoBook.h"
#import "ApolloDuoBookLayout.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoSubsChrome.h"
#import "ApolloState.h"

// Sibling detail host — not Mail-style dual-VC tiling inside one
// ApolloNavigationController. The old FeedSplit path pinned columns
// from viewDidLayout and caused overscroll ghosts / skippy comments
// / portrait leftovers. This host is a child of the tab controller,
// like the rail. Closed / Phone remove it and push the hosted
// comments back onto the posts nav so single-pane V1 is restored.

static char kApolloDuoBookHostKey;
static char kApolloDuoBookPlaceholderKey;
static char kApolloDuoBookDetailKey;
static char kApolloDuoBookDetailNavKey;
static char kApolloDuoBookActiveKey;
static char kApolloDuoBookPostureKey;
static char kApolloDuoBookSavedNavFrameKey;

static int sApolloDuoBookHingeStatus = ApolloDuoHingeUnknown;
static BOOL sApolloDuoBookHingeInstalled = NO;
static BOOL sApolloDuoBookHingeLogged = NO;
static unsigned sApolloDuoBookHingeEvents = 0;
static int sApolloDuoBookLastLogMode = -1;
static int sApolloDuoBookLastLogHinge = -1;
static int sApolloDuoBookLastLogPosture = -1;
static int sApolloDuoBookLastLogWant = -1;
static int sApolloDuoBookLastLogPosts = -1;
static double sApolloDuoBookLastLogUsable = -1.0;
static CFAbsoluteTime sApolloDuoBookLastLogAt = 0.0;

@interface ApolloDuoBookPlaceholderViewController : UIViewController
@end

@implementation ApolloDuoBookPlaceholderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Select a post";
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.textColor = [UIColor secondaryLabelColor];
    title.adjustsFontForContentSizeCategory = YES;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Tap a post in the feed to read it here.";
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    subtitle.textColor = [UIColor tertiaryLabelColor];
    subtitle.adjustsFontForContentSizeCategory = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24.0],
        [self.view.trailingAnchor constraintGreaterThanOrEqualToAnchor:stack.trailingAnchor constant:24.0],
    ]];
}

@end

static UITabBarController *ApolloDuoBookTabs(void) {
    UIViewController *tabs = ApolloMainTabBarController();
    return [tabs isKindOfClass:[UITabBarController class]] ? (UITabBarController *)tabs : nil;
}

static UINavigationController *ApolloDuoBookNavFromController(UIViewController *controller) {
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)controller;
    }
    if ([controller.navigationController isKindOfClass:[UINavigationController class]]) {
        return controller.navigationController;
    }
    return nil;
}

static BOOL ApolloDuoBookClassNamed(UIViewController *controller, const char *name) {
    Class cls = name ? objc_getClass(name) : Nil;
    return cls && controller && [controller isKindOfClass:cls];
}

// Copied from the V1 FeedSplit classifier: the posts nav also hosts
// Lite / search / saved-posts lists. First-slice adopt still requires
// a comments push; these names only decide "there is a feed on the left."
static BOOL ApolloDuoBookIsFeedController(UIViewController *controller) {
    return ApolloDuoBookClassNamed(controller, "_TtC6Apollo19PostsViewController")
        || ApolloDuoBookClassNamed(controller, "_TtC6Apollo23LitePostsViewController")
        || ApolloDuoBookClassNamed(controller, "_TtC6Apollo32SavedPostsCommentsViewController")
        || ApolloDuoBookClassNamed(controller, "_TtC6Apollo32PostsSearchResultsViewController");
}

static BOOL ApolloDuoBookIsCommentsController(UIViewController *controller) {
    if (!controller) return NO;
    if (ApolloSwipeCommentsIsPaneCommentsController(controller)) return NO;
    const char *name = class_getName(controller.class);
    return name && strstr(name, "CommentsViewController") != NULL
        && strstr(name, "SavedPosts") == NULL
        && strstr(name, "UserComments") == NULL;
}

static UINavigationController *ApolloDuoBookFindPostsNav(UITabBarController *tabs) {
    return ApolloDuoRailPostsNavigationController(tabs);
}

static int ApolloDuoBookLiveDuoMode(void) {
    UITabBarController *tabs = ApolloDuoBookTabs();
    UIWindow *window = (tabs.isViewLoaded && tabs.view.window)
        ? tabs.view.window : ApolloDeviceAppWindow();
    int stored = ApolloDuoCurrentMode();
    int dual = (stored != ApolloDuoModePhone) ? 1 : 0;
    int fromWindow = ApolloDuoModeFromWindow(window, dual);
    if (fromWindow == ApolloDuoModeOpen || stored == ApolloDuoModeOpen) {
        return ApolloDuoModeOpen;
    }
    if (fromWindow == ApolloDuoModeClosed || stored == ApolloDuoModeClosed) {
        return ApolloDuoModeClosed;
    }
    return ApolloDuoModePhone;
}

static void ApolloDuoBookLogDecision(int duoMode,
                                     int hinge,
                                     int posture,
                                     double usable,
                                     int onPostsTab,
                                     int want,
                                     const char *why) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int changed = (duoMode != sApolloDuoBookLastLogMode)
        || (hinge != sApolloDuoBookLastLogHinge)
        || (posture != sApolloDuoBookLastLogPosture)
        || (want != sApolloDuoBookLastLogWant)
        || (onPostsTab != sApolloDuoBookLastLogPosts)
        || (fabs(usable - sApolloDuoBookLastLogUsable) > 0.5);
    if (!changed && (now - sApolloDuoBookLastLogAt) < 2.0) return;
    sApolloDuoBookLastLogMode = duoMode;
    sApolloDuoBookLastLogHinge = hinge;
    sApolloDuoBookLastLogPosture = posture;
    sApolloDuoBookLastLogWant = want;
    sApolloDuoBookLastLogPosts = onPostsTab;
    sApolloDuoBookLastLogUsable = usable;
    sApolloDuoBookLastLogAt = now;
    ApolloLog(@"[DuoBook] sync mode=%d hinge=%d posture=%d usable=%.0f onPostsTab=%d want=%d why=%s",
              duoMode, hinge, posture, usable, onPostsTab, want, why ?: "-");
}

static int ApolloDuoBookMapHingeObject(id hinge) {
    if (!hinge) return ApolloDuoHingeUnknown;
    if ([hinge respondsToSelector:@selector(status)]) {
        NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(hinge, @selector(status));
        return ApolloDuoHingeStatusFromUIKit((int)status);
    }
    id boxed = nil;
    @try {
        boxed = [hinge valueForKey:@"status"];
    } @catch (__unused NSException *exception) {
        boxed = nil;
    }
    if ([boxed respondsToSelector:@selector(intValue)]) {
        return ApolloDuoHingeStatusFromUIKit([boxed intValue]);
    }
    return ApolloDuoHingeUnknown;
}

static void ApolloDuoBookSetHingeStatus(int status, const char *why) {
    int previous = sApolloDuoBookHingeStatus;
    sApolloDuoBookHingeEvents++;
    if (status != sApolloDuoBookHingeStatus || sApolloDuoBookHingeEvents <= 3) {
        ApolloLog(@"[DuoBook] hinge %d → %d (%s event=%u)",
                  previous, status, why ?: "update", sApolloDuoBookHingeEvents);
    }
    if (status == sApolloDuoBookHingeStatus) return;
    sApolloDuoBookHingeStatus = status;
    ApolloDuoCompatibilityFillSoon();
}

static void ApolloDuoBookInstallHinge(UIView *view) {
    if (sApolloDuoBookHingeInstalled || !view) return;
    Class interactionClass = objc_getClass("UIHingeInteraction");
    if (!interactionClass) {
        if (!sApolloDuoBookHingeLogged) {
            sApolloDuoBookHingeLogged = YES;
            ApolloLog(@"[DuoBook] UIHingeInteraction missing — posture uses window bounds (Open=fully-open, Closed=closed)");
        }
        return;
    }
    sApolloDuoBookHingeInstalled = YES;

    void (^handler1)(id) = ^(id hinge) {
        ApolloDuoBookSetHingeStatus(ApolloDuoBookMapHingeObject(hinge), "UIHingeInteraction");
    };
    void (^handler2)(id, id) = ^(id interaction, id hinge) {
        (void)interaction;
        ApolloDuoBookSetHingeStatus(ApolloDuoBookMapHingeObject(hinge), "UIHingeInteraction");
    };

    id interaction = nil;
    SEL initHandler = NSSelectorFromString(@"initWithUpdateHandler:");
    SEL initHingeHandler = NSSelectorFromString(@"initWithHandler:");
    if ([interactionClass instancesRespondToSelector:initHandler]) {
        interaction = ((id (*)(id, SEL, id))objc_msgSend)(
            [interactionClass alloc], initHandler, handler2);
    } else if ([interactionClass instancesRespondToSelector:initHingeHandler]) {
        interaction = ((id (*)(id, SEL, id))objc_msgSend)(
            [interactionClass alloc], initHingeHandler, handler1);
    } else {
        interaction = [[interactionClass alloc] init];
        if ([interaction respondsToSelector:NSSelectorFromString(@"setUpdateHandler:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                interaction, NSSelectorFromString(@"setUpdateHandler:"), handler2);
        }
    }
    if (interaction && [view respondsToSelector:@selector(addInteraction:)]) {
        [view addInteraction:interaction];
        id live = nil;
        if ([interaction respondsToSelector:@selector(hinge)]) {
            live = ((id (*)(id, SEL))objc_msgSend)(interaction, @selector(hinge));
        }
        if (live) {
            ApolloDuoBookSetHingeStatus(ApolloDuoBookMapHingeObject(live), "install-read");
        }
        if (!sApolloDuoBookHingeLogged) {
            sApolloDuoBookHingeLogged = YES;
            ApolloLog(@"[DuoBook] UIHingeInteraction installed on %@ hinge=%d",
                      NSStringFromClass(view.class), sApolloDuoBookHingeStatus);
        }
    }
}

static void ApolloDuoBookApplyFrame(UIView *view, CGRect frame, UIViewAutoresizing mask) {
    if (!view || CGRectGetWidth(frame) < 1.0 || CGRectGetHeight(frame) < 1.0) return;
    view.autoresizingMask = mask;
    if (fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(frame)) < 0.5
        && fabs(CGRectGetMinY(view.frame) - CGRectGetMinY(frame)) < 0.5
        && fabs(CGRectGetWidth(view.frame) - CGRectGetWidth(frame)) < 0.5
        && fabs(CGRectGetHeight(view.frame) - CGRectGetHeight(frame)) < 0.5) {
        return;
    }
    view.frame = frame;
}

static UIViewAutoresizing ApolloDuoBookPinRightMask(void) {
    return UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
}

static UIViewAutoresizing ApolloDuoBookFillMask(void) {
    return UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

static void ApolloDuoBookBringChromeFront(UITabBarController *tabs) {
    UIViewController *host = objc_getAssociatedObject(tabs, &kApolloDuoBookHostKey);
    if (host.view.superview == tabs.view) {
        [tabs.view bringSubviewToFront:host.view];
    }
    for (UIView *subview in tabs.view.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "ApolloDuoRail")) {
            [tabs.view bringSubviewToFront:subview];
            break;
        }
    }
}

static void ApolloDuoBookPinLeftContent(UITabBarController *tabs, int mode) {
    UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
    if (!posts.isViewLoaded || !posts.topViewController) return;
    CGRect bounds = tabs.view.bounds;
    ApolloFeedSplitFrames frames = ApolloDuoBookFramesForMode(bounds.size.width,
                                                              bounds.size.height,
                                                              mode);
    CGRect feed = CGRectMake((CGFloat)frames.feed.x, (CGFloat)frames.feed.y,
                             (CGFloat)frames.feed.width, (CGFloat)frames.feed.height);
    UIView *container = posts.view;
    CGRect inNav = [container convertRect:feed fromView:tabs.view];
    if (CGRectGetWidth(inNav) < 1.0 || CGRectGetHeight(inNav) < 1.0) {
        inNav = feed;
    }
    ApolloDuoRailFillPaneContentInRect(posts.topViewController, container, inNav);
    ApolloDuoSubsChromeApply(posts.topViewController);
}

static UIViewController *ApolloDuoBookHost(UITabBarController *tabs, BOOL create) {
    UIViewController *host = objc_getAssociatedObject(tabs, &kApolloDuoBookHostKey);
    if (host || !create) return host;
    host = [[UIViewController alloc] init];
    host.view.backgroundColor = [UIColor systemBackgroundColor];
    host.view.clipsToBounds = YES;
    objc_setAssociatedObject(tabs, &kApolloDuoBookHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloDuoBookPlaceholderViewController *placeholder =
        [[ApolloDuoBookPlaceholderViewController alloc] init];
    objc_setAssociatedObject(tabs, &kApolloDuoBookPlaceholderKey, placeholder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:placeholder];
    placeholder.view.frame = host.view.bounds;
    placeholder.view.autoresizingMask = UIViewAutoresizingFlexibleWidth
        | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:placeholder.view];
    [placeholder didMoveToParentViewController:host];
    return host;
}

static UIViewController *ApolloDuoBookWrappedDetail(UIViewController *comments) {
    if (!comments) return nil;
    if ([comments isKindOfClass:[UINavigationController class]]) return comments;
    // Stock nav — do not wrap the tab's ApolloNavigationController
    // (settings / floating tabs / URL routing treat that as the tab).
    return [[UINavigationController alloc] initWithRootViewController:comments];
}

static void ApolloDuoBookClearDetail(UITabBarController *tabs, BOOL pushBackOntoPosts) {
    UIViewController *detail = objc_getAssociatedObject(tabs, &kApolloDuoBookDetailKey);
    UIViewController *detailNav = objc_getAssociatedObject(tabs, &kApolloDuoBookDetailNavKey);
    UIViewController *host = objc_getAssociatedObject(tabs, &kApolloDuoBookHostKey);
    UIViewController *placeholder = objc_getAssociatedObject(tabs, &kApolloDuoBookPlaceholderKey);
    if (!detail && !detailNav) return;

    UIViewController *toMove = detail;
    if (detailNav) {
        if ([detailNav isKindOfClass:[UINavigationController class]]
            && toMove
            && toMove.navigationController == (UINavigationController *)detailNav) {
            [(UINavigationController *)detailNav setViewControllers:@[] animated:NO];
        }
        [detailNav willMoveToParentViewController:nil];
        [detailNav.view removeFromSuperview];
        [detailNav removeFromParentViewController];
    }
    objc_setAssociatedObject(tabs, &kApolloDuoBookDetailKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabs, &kApolloDuoBookDetailNavKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (placeholder && placeholder.parentViewController != host && host) {
        [host addChildViewController:placeholder];
        placeholder.view.frame = host.view.bounds;
        placeholder.view.autoresizingMask = UIViewAutoresizingFlexibleWidth
            | UIViewAutoresizingFlexibleHeight;
        [host.view addSubview:placeholder.view];
        [placeholder didMoveToParentViewController:host];
    }

    if (pushBackOntoPosts && toMove) {
        UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
        if (posts && ![posts.viewControllers containsObject:toMove]) {
            [posts pushViewController:toMove animated:NO];
            ApolloLog(@"[DuoBook] tear-down pushed hosted comments back onto the posts nav");
        }
    }
}

static void ApolloDuoBookShowDetail(UITabBarController *tabs, UIViewController *comments) {
    if (!tabs || !comments) return;
    UIViewController *host = ApolloDuoBookHost(tabs, YES);
    UIViewController *placeholder = objc_getAssociatedObject(tabs, &kApolloDuoBookPlaceholderKey);
    UIViewController *existing = objc_getAssociatedObject(tabs, &kApolloDuoBookDetailKey);
    UIViewController *existingNav = objc_getAssociatedObject(tabs, &kApolloDuoBookDetailNavKey);
    if (existing == comments && existingNav.parentViewController == host) {
        return;
    }

    if (existingNav) {
        [existingNav willMoveToParentViewController:nil];
        [existingNav.view removeFromSuperview];
        [existingNav removeFromParentViewController];
    }
    if (placeholder.parentViewController == host) {
        [placeholder willMoveToParentViewController:nil];
        [placeholder.view removeFromSuperview];
        [placeholder removeFromParentViewController];
    }

    UIViewController *wrapped = ApolloDuoBookWrappedDetail(comments);
    objc_setAssociatedObject(tabs, &kApolloDuoBookDetailKey, comments,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabs, &kApolloDuoBookDetailNavKey, wrapped,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:wrapped];
    wrapped.view.frame = host.view.bounds;
    wrapped.view.autoresizingMask = UIViewAutoresizingFlexibleWidth
        | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:wrapped.view];
    [wrapped didMoveToParentViewController:host];
    ApolloLog(@"[DuoBook] hosted %@ in the right pane", NSStringFromClass(comments.class));
}

static void ApolloDuoBookRestorePostsNav(UITabBarController *tabs) {
    UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
    if (!posts || !posts.isViewLoaded) return;
    UIView *superview = posts.view.superview;
    if (superview) {
        ApolloDuoBookApplyFrame(posts.view, superview.bounds, ApolloDuoBookFillMask());
    }
    objc_setAssociatedObject(posts, &kApolloDuoBookSavedNavFrameKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoBookTearDown(UITabBarController *tabs, const char *why) {
    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoBookActiveKey) boolValue];
    ApolloDuoBookClearDetail(tabs, YES);
    UIViewController *host = objc_getAssociatedObject(tabs, &kApolloDuoBookHostKey);
    if (host) {
        [host willMoveToParentViewController:nil];
        [host.view removeFromSuperview];
        [host removeFromParentViewController];
    }
    ApolloDuoBookRestorePostsNav(tabs);
    objc_setAssociatedObject(tabs, &kApolloDuoBookActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (wasActive) {
        ApolloLog(@"[DuoBook] torn down (%s) — stock single-pane restored", why ?: "closed");
    }
}

static void ApolloDuoBookApplyFrames(UITabBarController *tabs, int mode) {
    if (!tabs.isViewLoaded) return;
    CGRect bounds = tabs.view.bounds;
    ApolloFeedSplitFrames frames = ApolloDuoBookFramesForMode(bounds.size.width,
                                                              bounds.size.height,
                                                              mode);
    if (!frames.showsDetail || frames.feed.width < 1.0 || frames.detail.width < 1.0) {
        ApolloDuoBookTearDown(tabs, "frames-unusable");
        return;
    }

    // Do not shrink posts.view. UITabBarController resets the selected
    // child's frame to full bounds on every layout, which undoes a
    // half-width nav and then V1 rail fill expands the feed again.
    // Overlay the host on the right and pin list/feed content left.
    UIViewController *host = ApolloDuoBookHost(tabs, YES);
    if (host.parentViewController != tabs) {
        [tabs addChildViewController:host];
        [tabs.view addSubview:host.view];
        [host didMoveToParentViewController:tabs];
    }
    CGRect detailFrame = CGRectMake((CGFloat)frames.detail.x, (CGFloat)frames.detail.y,
                                    (CGFloat)frames.detail.width, (CGFloat)frames.detail.height);
    ApolloDuoBookApplyFrame(host.view, detailFrame, ApolloDuoBookPinRightMask());
    UIViewController *child = host.childViewControllers.firstObject;
    if (child.isViewLoaded) {
        ApolloDuoBookApplyFrame(child.view, host.view.bounds, ApolloDuoBookFillMask());
    }

    ApolloDuoBookPinLeftContent(tabs, mode);
    ApolloDuoBookBringChromeFront(tabs);
}

BOOL ApolloDuoBookIsActive(void) {
    UITabBarController *tabs = ApolloDuoBookTabs();
    return [objc_getAssociatedObject(tabs, &kApolloDuoBookActiveKey) boolValue];
}

int ApolloDuoBookCurrentPosture(void) {
    UITabBarController *tabs = ApolloDuoBookTabs();
    NSNumber *stored = objc_getAssociatedObject(tabs, &kApolloDuoBookPostureKey);
    if (stored) return stored.intValue;
    return ApolloDuoBookPostureFromState(ApolloDuoBookLiveDuoMode(),
                                         sApolloDuoBookHingeStatus);
}

int ApolloDuoBookCurrentHingeStatus(void) {
    return sApolloDuoBookHingeStatus;
}

BOOL ApolloDuoBookAdoptPush(UINavigationController *nav, UIViewController *viewController) {
    if (!ApolloDuoBookIsActive() || !nav || !viewController) return NO;
    UITabBarController *tabs = ApolloDuoBookTabs();
    UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
    if (nav != posts) return NO;
    if (!ApolloDuoBookIsCommentsController(viewController)) return NO;

    BOOL feedOnStack = NO;
    for (UIViewController *vc in nav.viewControllers) {
        if (ApolloDuoBookIsFeedController(vc)) {
            feedOnStack = YES;
            break;
        }
    }
    if (!feedOnStack && !ApolloDuoBookIsFeedController(nav.topViewController)) {
        ApolloLog(@"[DuoBook] comments push skipped (no feed on the posts nav)");
        return NO;
    }

    ApolloDuoBookShowDetail(tabs, viewController);
    ApolloDuoBookSync();
    return YES;
}

void ApolloDuoBookReassertFrames(void) {
    UITabBarController *tabs = ApolloDuoBookTabs();
    if (!tabs || !ApolloDuoBookIsActive()) return;
    ApolloDuoBookApplyFrames(tabs, ApolloDuoBookLiveDuoMode());
}

void ApolloDuoBookSync(void) {
    UITabBarController *tabs = ApolloDuoBookTabs();
    if (!tabs || !tabs.isViewLoaded) {
        ApolloDuoBookLogDecision(ApolloDuoCurrentMode(), sApolloDuoBookHingeStatus,
                                 ApolloDuoBookPosturePhone, 0.0, 0, 0, "tabs-unready");
        return;
    }

    ApolloDuoBookInstallHinge(tabs.view.window ?: tabs.view);

    int duoMode = ApolloDuoBookLiveDuoMode();
    int posture = ApolloDuoBookPostureFromState(duoMode, sApolloDuoBookHingeStatus);
    CGSize size = tabs.view.bounds.size;
    UIWindow *window = (tabs.isViewLoaded && tabs.view.window)
        ? tabs.view.window : ApolloDeviceAppWindow();
    if (window && window.bounds.size.width > size.width + 0.5) {
        size = window.bounds.size;
    }
    double extraLeft = ApolloDuoBookExtraLeftForMode(duoMode);
    double extraRight = ApolloDuoBookExtraRightForMode(duoMode);
    double usable = ApolloFeedSplitUsableWidth(size.width, extraLeft, extraRight);
    UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
    UINavigationController *selected = ApolloDuoBookNavFromController(tabs.selectedViewController);
    BOOL onPostsTab = posts && selected && (posts == selected
        || [posts.viewControllers containsObject:tabs.selectedViewController]);
    BOOL wideEnough = ApolloDuoBookSplitShouldEnable(posture, usable) ? YES : NO;
    BOOL want = onPostsTab && wideEnough;
    const char *why = "split";
    if (duoMode == ApolloDuoModePhone) {
        why = "phone";
    } else if (!onPostsTab) {
        why = "not-posts-tab";
    } else if (!wideEnough) {
        why = ApolloDuoBookPostureAllowsSplit(posture) ? "narrow" : "closed";
    }

    objc_setAssociatedObject(tabs, &kApolloDuoBookPostureKey, @(posture),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoBookLogDecision(duoMode, sApolloDuoBookHingeStatus, posture,
                             usable, onPostsTab ? 1 : 0, want ? 1 : 0, why);

    if (!want) {
        ApolloDuoBookTearDown(tabs, why);
        return;
    }

    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoBookActiveKey) boolValue];
    objc_setAssociatedObject(tabs, &kApolloDuoBookActiveKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoBookApplyFrames(tabs, duoMode);
    if (!wasActive) {
        ApolloLog(@"[DuoBook] shown posture=%d mode=%d hinge=%d window=%.0fx%.0f",
                  posture, duoMode, sApolloDuoBookHingeStatus,
                  size.width, size.height);
    }
}
