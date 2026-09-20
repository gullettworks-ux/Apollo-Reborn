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
static char kApolloDuoBookSavedSafeInsetsKey;

static int sApolloDuoBookHingeStatus = ApolloDuoHingeUnknown;
static BOOL sApolloDuoBookHingeInstalled = NO;
static BOOL sApolloDuoBookHingeLogged = NO;
static unsigned sApolloDuoBookHingeEvents = 0;
static int sApolloDuoBookLastLogMode = -1;
static int sApolloDuoBookLastLogHinge = -1;
static int sApolloDuoBookLastLogPosture = -1;
static int sApolloDuoBookLastLogWant = -1;
static int sApolloDuoBookLastLogPosts = -1;
static int sApolloDuoBookLastLogHint = -1;
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

static int ApolloDuoBookDuoHint(void) {
    if (sApolloDuoBookHingeInstalled) return 1;
    if (objc_getClass("UIHingeInteraction")) return 1;
    if (ApolloDuoRailIsActive()) return 1;
    if (IsLiquidGlass()) return 1;
    CGSize sizes[4];
    unsigned count = 0;
    for (UIScreen *screen in [UIScreen screens]) {
        CGSize size = screen.bounds.size;
        if (size.width <= 0.0 || size.height <= 0.0) continue;
        unsigned i;
        int seen = 0;
        for (i = 0; i < count; i++) {
            if (fabs(sizes[i].width - size.width) < 1.0
                && fabs(sizes[i].height - size.height) < 1.0) {
                seen = 1;
                break;
            }
        }
        if (!seen && count < 4) sizes[count++] = size;
    }
    if (count >= 2
        && ApolloDisplayScreensAreDual(sizes[0].width, sizes[0].height,
                                       sizes[1].width, sizes[1].height)) {
        return 1;
    }
    return 0;
}

static void ApolloDuoBookLogDecision(int duoMode,
                                     int hinge,
                                     int posture,
                                     double usable,
                                     int onPostsTab,
                                     int want,
                                     int hint,
                                     const char *why) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int changed = (duoMode != sApolloDuoBookLastLogMode)
        || (hinge != sApolloDuoBookLastLogHinge)
        || (posture != sApolloDuoBookLastLogPosture)
        || (want != sApolloDuoBookLastLogWant)
        || (onPostsTab != sApolloDuoBookLastLogPosts)
        || (hint != sApolloDuoBookLastLogHint)
        || (fabs(usable - sApolloDuoBookLastLogUsable) > 0.5);
    if (!changed && (now - sApolloDuoBookLastLogAt) < 2.0) return;
    sApolloDuoBookLastLogMode = duoMode;
    sApolloDuoBookLastLogHinge = hinge;
    sApolloDuoBookLastLogPosture = posture;
    sApolloDuoBookLastLogWant = want;
    sApolloDuoBookLastLogPosts = onPostsTab;
    sApolloDuoBookLastLogHint = hint;
    sApolloDuoBookLastLogUsable = usable;
    sApolloDuoBookLastLogAt = now;
    ApolloLog(@"[DuoBook] sync mode=%d hinge=%d posture=%d usable=%.0f onPostsTab=%d want=%d hint=%d why=%s",
              duoMode, hinge, posture, usable, onPostsTab, want, hint, why ?: "-");
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

static void ApolloDuoBookRestoreSafeInsets(UIViewController *controller);
static void ApolloDuoBookApplyDetailInsets(UIViewController *host);

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
    ApolloDuoBookRestoreSafeInsets(detail);
    ApolloDuoBookRestoreSafeInsets(detailNav);
    ApolloDuoBookRestoreSafeInsets(host);
    ApolloDuoBookRestoreSafeInsets(placeholder);
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

static void ApolloDuoBookApplySafeInsets(UIViewController *controller) {
    if (!controller) return;
    UIEdgeInsets want = UIEdgeInsetsMake(0.0,
                                         (CGFloat)ApolloDuoBookDetailSafeLeft(),
                                         (CGFloat)ApolloDuoBookDetailSafeBottom(),
                                         (CGFloat)ApolloDuoBookDetailSafeRight());
    if (!objc_getAssociatedObject(controller, &kApolloDuoBookSavedSafeInsetsKey)) {
        objc_setAssociatedObject(controller, &kApolloDuoBookSavedSafeInsetsKey,
                                 [NSValue valueWithUIEdgeInsets:controller.additionalSafeAreaInsets],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIEdgeInsets current = controller.additionalSafeAreaInsets;
    if (fabs(current.left - want.left) < 0.5
        && fabs(current.right - want.right) < 0.5
        && fabs(current.bottom - want.bottom) < 0.5) {
        return;
    }
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, want.left,
                                                           want.bottom, want.right);
}

static void ApolloDuoBookRestoreSafeInsets(UIViewController *controller) {
    if (!controller) return;
    NSValue *saved = objc_getAssociatedObject(controller, &kApolloDuoBookSavedSafeInsetsKey);
    if (!saved) return;
    controller.additionalSafeAreaInsets = saved.UIEdgeInsetsValue;
    objc_setAssociatedObject(controller, &kApolloDuoBookSavedSafeInsetsKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloDuoBookFindJumpButton(UIViewController *comments) {
    if (!comments.isViewLoaded) return nil;
    Ivar ivar = class_getInstanceVariable(comments.class, "commentJumpButton");
    UIView *button = ivar ? object_getIvar(comments, ivar) : nil;
    if ([button isKindOfClass:[UIView class]]) return button;

    UIView *root = comments.view;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestScore = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 120) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (![view isKindOfClass:[UIControl class]]) continue;
        CGFloat w = CGRectGetWidth(view.bounds);
        CGFloat h = CGRectGetHeight(view.bounds);
        if (w < 36.0 || w > 72.0 || h < 36.0 || h > 72.0) continue;
        if (fabs(w - h) > 8.0) continue;
        CGRect inRoot = [root convertRect:view.bounds fromView:view];
        if (CGRectGetMidX(inRoot) < rootW * 0.55) continue;
        if (CGRectGetMidY(inRoot) < rootH * 0.55) continue;
        CGFloat score = CGRectGetMaxX(inRoot) + CGRectGetMaxY(inRoot);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

static void ApolloDuoBookAdjustJumpButton(UIViewController *comments) {
    if (!comments) return;
    const char *name = class_getName(comments.class);
    if (!name || strstr(name, "CommentsViewController") == NULL) return;
    UIView *button = ApolloDuoBookFindJumpButton(comments);
    if (![button isKindOfClass:[UIView class]] || !button.superview) return;
    UIView *container = button.superview;
    CGRect frame = button.frame;
    CGFloat limitX = (CGFloat)ApolloDuoBookJumpMaxX(CGRectGetWidth(container.bounds));
    CGFloat limitY = (CGFloat)ApolloDuoBookJumpMaxY(CGRectGetHeight(container.bounds));
    BOOL moved = NO;
    if (CGRectGetMaxX(frame) > limitX + 0.5) {
        frame.origin.x -= (CGRectGetMaxX(frame) - limitX);
        moved = YES;
    }
    if (CGRectGetMaxY(frame) > limitY + 0.5) {
        frame.origin.y -= (CGRectGetMaxY(frame) - limitY);
        moved = YES;
    }
    if (frame.origin.x < 0.0) frame.origin.x = 0.0;
    if (frame.origin.y < 0.0) frame.origin.y = 0.0;
    if (moved) button.frame = frame;
}

static void ApolloDuoBookApplyDetailInsets(UIViewController *host) {
    if (!host) return;
    ApolloDuoBookApplySafeInsets(host);
    for (UIViewController *child in host.childViewControllers) {
        ApolloDuoBookApplySafeInsets(child);
        if ([child isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)child;
            for (UIViewController *page in nav.viewControllers) {
                ApolloDuoBookApplySafeInsets(page);
                ApolloDuoBookAdjustJumpButton(page);
            }
        } else {
            ApolloDuoBookAdjustJumpButton(child);
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
    ApolloDuoBookApplyDetailInsets(host);
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
    ApolloDuoBookApplyDetailInsets(host);

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
    CGSize size = CGSizeZero;
    if (tabs.isViewLoaded) size = tabs.view.bounds.size;
    if (size.width < 1.0) {
        UIWindow *window = ApolloDeviceAppWindow();
        if (window) size = window.bounds.size;
    }
    return ApolloDuoBookPostureFromCanvas(ApolloDuoBookLiveDuoMode(),
                                          sApolloDuoBookHingeStatus,
                                          size.width, size.height,
                                          ApolloDuoBookDuoHint());
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
                                 ApolloDuoBookPosturePhone, 0.0, 0, 0, 0, "tabs-unready");
        return;
    }

    ApolloDuoBookInstallHinge(tabs.view.window ?: tabs.view);

    int duoMode = ApolloDuoBookLiveDuoMode();
    int hint = ApolloDuoBookDuoHint();
    CGSize size = tabs.view.bounds.size;
    UIWindow *window = (tabs.isViewLoaded && tabs.view.window)
        ? tabs.view.window : ApolloDeviceAppWindow();
    if (window && window.bounds.size.width > size.width + 0.5) {
        size = window.bounds.size;
    }
    int frameMode = (duoMode == ApolloDuoModeOpen || ApolloDuoRailIsActive())
        ? ApolloDuoModeOpen : ApolloDuoModePhone;
    double extraLeft = ApolloDuoBookExtraLeftForMode(frameMode);
    double extraRight = ApolloDuoBookExtraRightForMode(frameMode);
    double usable = ApolloFeedSplitUsableWidth(size.width, extraLeft, extraRight);
    int posture = ApolloDuoBookPostureFromCanvas(duoMode, sApolloDuoBookHingeStatus,
                                                 usable, size.height, hint);
    UINavigationController *posts = ApolloDuoBookFindPostsNav(tabs);
    UINavigationController *selected = ApolloDuoBookNavFromController(tabs.selectedViewController);
    BOOL onPostsTab = posts && selected && (posts == selected
        || [posts.viewControllers containsObject:tabs.selectedViewController]);
    BOOL wideEnough = ApolloDuoBookSplitShouldEnable(posture, usable) ? YES : NO;
    BOOL want = onPostsTab && wideEnough;
    const char *why = "split";
    if (!onPostsTab) {
        why = "not-posts-tab";
    } else if (!wideEnough) {
        if (posture == ApolloDuoBookPostureClosed) why = "closed";
        else if (posture == ApolloDuoBookPosturePhone) why = "phone";
        else why = "narrow";
    }

    objc_setAssociatedObject(tabs, &kApolloDuoBookPostureKey, @(posture),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoBookLogDecision(duoMode, sApolloDuoBookHingeStatus, posture,
                             usable, onPostsTab ? 1 : 0, want ? 1 : 0, hint, why);

    if (!want) {
        ApolloDuoBookTearDown(tabs, why);
        return;
    }

    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoBookActiveKey) boolValue];
    objc_setAssociatedObject(tabs, &kApolloDuoBookActiveKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoBookApplyFrames(tabs, frameMode);
    if (!wasActive) {
        ApolloLog(@"[DuoBook] shown posture=%d mode=%d hinge=%d hint=%d window=%.0fx%.0f",
                  posture, duoMode, sApolloDuoBookHingeStatus, hint,
                  size.width, size.height);
    }
}
