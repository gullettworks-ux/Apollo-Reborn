#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloDuoSubsChrome.h"
#import "ApolloFeedSplitLayout.h"
#import "ApolloThemeRuntime.h"

// One Duo chrome path. Open Duo (wide landscape UIWindow) is a
// reserved leading 112pt sidebar and hides UITabBar. Closed Duo
// (portrait-sized Duo window) is Phone-like: stock bottom tab bar,
// no Apollo side rail. Regular iPhone stays on the stock tab bar.
// Selected item uses the theme accent (blue on stock) as a rounded
// pill. FeedSplit tiling stays off.
//
// RedditList stars: native accessoryButton stays in-tree as the
// favorite action/state, but is hidden. A table-sibling overlay
// column (same host as A–Z) paints one star per visible row at
// X = A–Z leading − gap, or a tighter trailing-half nav pill.
// Synced to visibleCells on appear / scroll / willDisplay /
// Open↔Closed. Per-cell contentView pins and table layoutMargins
// are abandoned — neither moved accessoryButton (Favorites
// “Apple” stayed mid-pane; large trailing margins clipped titles).
// Closed has no side rail.
//
// Mode keys off UIWindow.bounds (never UIScreen.mainScreen). First
// show defaults to Subs: stock popToRoot onto RedditList. Navigation
// reuses Apollo's own tab selectors and RedditList row 0 (Home),
// plus apollo://reddit.com/r/popular|all.

typedef NS_ENUM(NSInteger, ApolloDuoRailItem) {
    ApolloDuoRailItemSubreddits = 0,
    ApolloDuoRailItemHome,
    ApolloDuoRailItemPopular,
    ApolloDuoRailItemAll,
    ApolloDuoRailItemProfile,
    ApolloDuoRailItemSettings,
    ApolloDuoRailItemCount,
};

static const char *kApolloDuoRailTitles[] = {
    "Posts/Subs", "Home", "Popular", "All", "Profile", "Settings",
};
static const char *kApolloDuoRailSymbols[] = {
    "list.bullet", "house", "flame", "globe", "person", "gearshape",
};

static char kApolloDuoRailViewKey;
static char kApolloDuoRailActiveKey;
static char kApolloDuoRailModeKey;
static char kApolloDuoRailSelectedKey;
static char kApolloDuoRailSavedContentInsetLeftKey;
static char kApolloDuoRailSavedPreferredSizeKey;
static char kApolloDuoRailSavedAdditionalLeftKey;
static char kApolloDuoRailSavedSeparatorRightKey;
static char kApolloDuoRailRowLeadingClaimedKey;
static char kApolloDuoRailRowDisabledConstraintsKey;
static char kApolloDuoRailRowMarginsResetKey;
static char kApolloDuoRailRowStarRetryKey;
static char kApolloDuoRailRowStarRetryScheduledKey;
static char kApolloDuoRailRowLastModeKey;
static char kApolloDuoRailRowLastContentWidthKey;
static char kApolloDuoRailNativeStarHiddenKey;
static char kApolloDuoRailStarColumnKey;
static BOOL sApolloDuoRailDeferredScheduled = NO;
static BOOL sApolloDuoRailAfterLayoutScheduled = NO;
static int sApolloDuoRailDeferredAttempt = 0;
static int sApolloDuoRailLastReanchorMode = -1;
static BOOL sApolloDuoRailPickingSubreddits = NO;
static BOOL sApolloDuoRailOpenedDefaultDirectory = NO;

BOOL ApolloDuoRailIsPickingSubreddits(void) {
    return sApolloDuoRailPickingSubreddits;
}

void ApolloDuoRailSetPickingSubreddits(BOOL picking) {
    if (sApolloDuoRailPickingSubreddits == picking) return;
    sApolloDuoRailPickingSubreddits = picking;
    ApolloLog(@"[DuoRail] My Subreddits picking=%d", picking ? 1 : 0);
}

static UINavigationController *ApolloDuoRailNavFromController(UIViewController *controller) {
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)controller;
    }
    if ([controller.navigationController isKindOfClass:[UINavigationController class]]) {
        return controller.navigationController;
    }
    return nil;
}

// Posts tab without goToHomeTab — that selector pops to RedditList / opens
// Home and would wipe a restored directory (or race a feed push that
// re-dismisses RedditList while picking is YES).
static UINavigationController *ApolloDuoRailFindPostsNav(UITabBarController *tabs, BOOL selectTab) {
    if (!tabs) return nil;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class apolloNav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    UINavigationController *best = nil;
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = ApolloDuoRailNavFromController(child);
        if (!nav) continue;
        BOOL looksPosts = NO;
        for (UIViewController *vc in nav.viewControllers) {
            if ((listClass && [vc isKindOfClass:listClass])
                || (postsClass && [vc isKindOfClass:postsClass])) {
                looksPosts = YES;
                break;
            }
        }
        if (looksPosts) {
            best = nav;
            break;
        }
        if (!best && apolloNav && [nav isKindOfClass:apolloNav]) {
            best = nav;
        }
    }
    if (!best && tabs.viewControllers.count > 0) {
        best = ApolloDuoRailNavFromController(tabs.viewControllers.firstObject);
    }
    if (selectTab && best && tabs.selectedViewController != best
        && [tabs.viewControllers containsObject:best]) {
        tabs.selectedViewController = best;
    }
    return best;
}

static UINavigationController *ApolloDuoRailPostsNav(UITabBarController *tabs) {
    if (!tabs) return nil;
    if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
        } @catch (NSException *exception) {
            ApolloLog(@"[DuoRail] goToHomeTab threw: %@", exception);
        }
    }
    return ApolloDuoRailNavFromController(tabs.selectedViewController)
        ?: ApolloDuoRailFindPostsNav(tabs, NO);
}

static BOOL ApolloDuoRailOpenListRow(UINavigationController *nav, NSInteger row) {
    if (!nav) return NO;
    [nav popToRootViewControllerAnimated:NO];
    UIViewController *root = nav.viewControllers.firstObject;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!listClass || ![root isKindOfClass:listClass]) {
        ApolloLog(@"[DuoRail] Posts root is not RedditListViewController (%@)", root);
        return NO;
    }
    if (!root.isViewLoaded) [root loadViewIfNeeded];
    UITableView *tableView = nil;
    if ([root respondsToSelector:@selector(tableView)]) {
        @try {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(root, @selector(tableView));
        } @catch (NSException *exception) {
            ApolloLog(@"[DuoRail] tableView read failed: %@", exception);
        }
    }
    if (![root respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(root, @selector(tableView:didSelectRowAtIndexPath:), tableView, path);
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[DuoRail] didSelectRow failed: %@", exception);
        return NO;
    }
}

static void ApolloDuoRailPerformItem(ApolloDuoRailItem item) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[DuoRail] no tab bar controller yet");
        return;
    }
    objc_setAssociatedObject(tabs, &kApolloDuoRailSelectedKey, @(item), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (item == ApolloDuoRailItemProfile) {
        ApolloDuoRailSetPickingSubreddits(NO);
        if ([tabs respondsToSelector:@selector(goToProfileTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToProfileTab));
        }
        return;
    }
    if (item == ApolloDuoRailItemSettings) {
        ApolloDuoRailSetPickingSubreddits(NO);
        if ([tabs respondsToSelector:@selector(goToSettingsTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToSettingsTab));
        }
        return;
    }

    if (item == ApolloDuoRailItemSubreddits) {
        UINavigationController *nav = ApolloDuoRailFindPostsNav(tabs, YES);
        ApolloFeedSplitShowSubredditPicker(nav);
        return;
    }
    UINavigationController *nav = ApolloDuoRailPostsNav(tabs);
    ApolloDuoRailSetPickingSubreddits(NO);
    if (item == ApolloDuoRailItemHome) {
        if (ApolloDuoRailOpenListRow(nav, 0)) {
            ApolloLog(@"[DuoRail] opened Home feed");
        }
        return;
    }

    NSURL *url = nil;
    if (item == ApolloDuoRailItemPopular) {
        url = [NSURL URLWithString:@"apollo://reddit.com/r/popular"];
    } else if (item == ApolloDuoRailItemAll) {
        url = [NSURL URLWithString:@"apollo://reddit.com/r/all"];
    }
    if (url && ApolloRouteURLThroughApp(url)) {
        ApolloLog(@"[DuoRail] routed %@", url.absoluteString);
        return;
    }
    ApolloLog(@"[DuoRail] URL route failed for item %ld", (long)item);
}

@interface ApolloDuoRailButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation ApolloDuoRailButton

- (instancetype)initWithItem:(ApolloDuoRailItem)item {
    self = [super initWithFrame:CGRectZero];
    if (!self) return self;
    self.tag = item;
    self.isAccessibilityElement = YES;
    NSString *title = [NSString stringWithUTF8String:kApolloDuoRailTitles[item]];
    self.accessibilityLabel = (item == ApolloDuoRailItemSubreddits) ? @"Posts / Subreddits" : title;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
        self.iconView.image = [UIImage systemImageNamed:[NSString stringWithUTF8String:kApolloDuoRailSymbols[item]]
                                      withConfiguration:config];
    }
    [self addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = title;
    self.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.72;
    [self addSubview:self.titleLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat icon = 20.0;
    CGFloat iconY = 8.0;
    self.iconView.frame = CGRectMake((width - icon) * 0.5, iconY, icon, icon);
    self.titleLabel.frame = CGRectMake(3.0, iconY + icon + 4.0, width - 6.0, MAX(13.0, height - iconY - icon - 8.0));
}

- (void)apollo_applyForeground:(UIColor *)color selected:(BOOL)selected fill:(UIColor *)fill {
    self.backgroundColor = selected ? fill : UIColor.clearColor;
    self.iconView.tintColor = color;
    self.titleLabel.textColor = color;
    self.titleLabel.font = selected
        ? [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold]
        : [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.accessibilityTraits = selected
        ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected)
        : UIAccessibilityTraitButton;
}

@end

@interface ApolloDuoRailView : UIView
@property (nonatomic, copy) NSArray<ApolloDuoRailButton *> *buttons;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, assign) ApolloDuoRailItem selectedItem;
@property (nonatomic, assign) BOOL leading;
- (void)apollo_applyTheme;
- (void)apollo_setSelectedItem:(ApolloDuoRailItem)item;
@end

@implementation ApolloDuoRailView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;
    self.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    self.accessibilityTraits = UIAccessibilityTraitTabBar;

    NSMutableArray<ApolloDuoRailButton *> *buttons = [NSMutableArray arrayWithCapacity:ApolloDuoRailItemCount];
    for (NSInteger i = 0; i < ApolloDuoRailItemCount; i++) {
        ApolloDuoRailButton *button = [[ApolloDuoRailButton alloc] initWithItem:(ApolloDuoRailItem)i];
        [button addTarget:self action:@selector(apollo_tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    self.separatorView = [[UIView alloc] initWithFrame:CGRectZero];
    self.separatorView.userInteractionEnabled = NO;
    [self addSubview:self.separatorView];
    self.selectedItem = ApolloDuoRailItemSubreddits;
    self.leading = YES;
    [self apollo_applyTheme];
    return self;
}

- (void)apollo_tapped:(ApolloDuoRailButton *)sender {
    ApolloDuoRailItem item = (ApolloDuoRailItem)sender.tag;
    [self apollo_setSelectedItem:item];
    ApolloDuoRailPerformItem(item);
}

- (void)apollo_setSelectedItem:(ApolloDuoRailItem)item {
    self.selectedItem = item;
    [self apollo_applyTheme];
}

- (void)apollo_applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    UIColor *muted = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    self.backgroundColor = page;
    self.separatorView.backgroundColor = ApolloThemeSeparatorColor()
        ?: (UIColor.separatorColor ?: [UIColor colorWithWhite:0.0 alpha:0.08]);
    UIColor *onAccent = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    for (ApolloDuoRailButton *button in self.buttons) {
        BOOL selected = button.tag == (NSInteger)self.selectedItem;
        [button apollo_applyForeground:(selected ? onAccent : muted) selected:selected fill:accent];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Frame already starts at safe.top + 8. Keep Profile / Settings
    // docked to the bottom; the four feed items stay a compact stack.
    CGFloat top = 10.0;
    CGFloat bottom = 10.0;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat usable = height - top - bottom;
    if (usable < 1.0) return;

    NSInteger count = (NSInteger)self.buttons.count;
    CGFloat itemHeight = MIN(62.0, usable / (CGFloat)count);
    CGFloat y = top;
    for (NSInteger i = 0; i < count; i++) {
        UIView *button = self.buttons[(NSUInteger)i];
        if (i == ApolloDuoRailItemProfile) {
            CGFloat remaining = height - bottom - (itemHeight * 2.0);
            if (remaining > y) y = remaining;
        }
        button.frame = CGRectMake(7.0, y, width - 14.0, itemHeight - 6.0);
        y += itemHeight;
    }
    CGFloat hairline = 1.0 / MAX(self.window.screen.scale, 1.0);
    CGFloat separatorX = self.leading ? (width - hairline) : 0.0;
    self.separatorView.frame = CGRectMake(separatorX, 0.0, hairline, height);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self apollo_applyTheme];
}

@end

static BOOL ApolloDuoRailDualDisplays(void) {
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    for (UIScreen *screen in [UIScreen screens]) {
        CGSize size = screen.bounds.size;
        if (size.width <= 0.0 || size.height <= 0.0) continue;
        BOOL seen = NO;
        for (NSValue *value in sizes) {
            CGSize existing = value.CGSizeValue;
            if (fabs(existing.width - size.width) < 1.0 && fabs(existing.height - size.height) < 1.0) {
                seen = YES;
                break;
            }
        }
        if (!seen) [sizes addObject:[NSValue valueWithCGSize:size]];
    }
    if (sizes.count < 2) return NO;
    CGSize a = sizes[0].CGSizeValue;
    CGSize b = sizes[1].CGSizeValue;
    return ApolloDisplayScreensAreDual(a.width, a.height, b.width, b.height);
}

static int ApolloDuoRailModeForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) {
        return ApolloDuoModePhone;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return ApolloDuoModePhone;
    }
    UIWindow *window = tabs.view.window ?: ApolloDeviceAppWindow();
    return ApolloDuoModeFromWindow(window, ApolloDuoRailDualDisplays() ? 1 : 0);
}

static int ApolloDuoRailCurrentMode(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    NSNumber *stored = objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey);
    if (stored) return stored.intValue;
    return ApolloDuoRailModeForTabs(tabs);
}

static BOOL ApolloDuoRailIsLeading(void) {
    return ApolloDuoModeIsLeading(ApolloDuoRailCurrentMode());
}

static void ApolloDuoSubsChromeApplyToTabs(UITabBarController *tabs) {
    UINavigationController *nav = ApolloDuoRailNavFromController(tabs.selectedViewController);
    if (!nav) nav = ApolloDuoRailFindPostsNav(tabs, NO);
    UIViewController *top = nav.topViewController;
    if (top) ApolloDuoSubsChromeApply(top);
}

int ApolloDuoCurrentMode(void) {
    return ApolloDuoRailCurrentMode();
}

static void ApolloDuoRailSetTabBarHidden(UITabBarController *tabs, BOOL hidden) {
    if (!tabs) return;
    SEL setter = @selector(setTabBarHidden:animated:);
    if ([tabs respondsToSelector:setter]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tabs, setter, hidden, NO);
    } else {
        tabs.tabBar.hidden = hidden;
    }
    for (UIView *subview in tabs.view.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "TabContainer")) {
            subview.hidden = hidden;
        }
    }
}

// Launch / first rail show: Subs selected, stock RedditList (no tile).
static void ApolloDuoRailOpenDefaultDirectory(UITabBarController *tabs) {
    UINavigationController *nav = ApolloDuoRailFindPostsNav(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailSelectedKey,
                             @(ApolloDuoRailItemSubreddits), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoRailView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    [rail apollo_setSelectedItem:ApolloDuoRailItemSubreddits];
    ApolloFeedSplitShowSubredditPicker(nav);
    ApolloLog(@"[DuoRail] default Subs stock directory");
}

// Window/scene chrome only. The tab view's safeAreaInsets include our
// additionalSafeAreaInsets and would walk the rail if used for x.
static UIEdgeInsets ApolloDuoRailSystemSafeInsets(UITabBarController *tabs) {
    UIWindow *window = tabs.view.window;
    if (window) return window.safeAreaInsets;
    UIEdgeInsets viewSafe = tabs.view.safeAreaInsets;
    UIEdgeInsets extra = tabs.additionalSafeAreaInsets;
    return UIEdgeInsetsMake(MAX(0.0, viewSafe.top - extra.top),
                            MAX(0.0, viewSafe.left - extra.left),
                            MAX(0.0, viewSafe.bottom - extra.bottom),
                            MAX(0.0, viewSafe.right - extra.right));
}

CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView) {
    if (!ApolloDuoRailIsActive() || !tableView) return 0.0;
    return (CGFloat)ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoRailCurrentMode());
}

void ApolloDuoRailPinSectionIndex(UITableView *tableView) {
    if (!ApolloDuoRailIsActive() || !tableView) return;
    if (tableView.cellLayoutMarginsFollowReadableWidth) {
        tableView.cellLayoutMarginsFollowReadableWidth = NO;
    }
    CGFloat trailing = ApolloDuoRailSectionIndexTrailingForTable(tableView);
    if (trailing < 1.0) return;
    CGFloat wantMaxX = CGRectGetWidth(tableView.bounds) - trailing;
    for (UIView *subview in tableView.subviews) {
        const char *name = class_getName(subview.class);
        if (!name || !strstr(name, "TableViewIndex")) continue;
        CGRect frame = subview.frame;
        CGFloat maxX = CGRectGetMaxX(frame);
        if (fabs(maxX - wantMaxX) < 0.5) continue;
        frame.origin.x = wantMaxX - CGRectGetWidth(frame);
        if (frame.origin.x < 0.0) frame.origin.x = 0.0;
        subview.frame = frame;
    }
}

static void ApolloDuoWalkViewControllers(UIViewController *root, void (^block)(UIViewController *controller)) {
    if (!root || !block) return;
    block(root);
    for (UIViewController *child in root.childViewControllers) {
        ApolloDuoWalkViewControllers(child, block);
    }
    UIViewController *presented = root.presentedViewController;
    if (presented && presented.presentingViewController == root) {
        ApolloDuoWalkViewControllers(presented, block);
    }
}

static void ApolloDuoApplyInsetsToController(UIViewController *controller,
                                             CGFloat wantLeft,
                                             CGFloat wantBottom,
                                             CGFloat wantRight) {
    if (!controller) return;
    UIEdgeInsets current = controller.additionalSafeAreaInsets;
    if (fabs(current.left - wantLeft) < 0.5
        && fabs(current.right - wantRight) < 0.5
        && fabs(current.bottom - wantBottom) < 0.5) {
        return;
    }
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, wantLeft, wantBottom, wantRight);
}

// Show: only the tab controller and its tab-root navs get the leading
// content inset. Pushed content is frame-shifted instead so headers
// and Texture feeds clear the rail without stacking another inset.
static void ApolloDuoApplyChromeInsets(UITabBarController *tabs,
                                       CGFloat wantLeft,
                                       CGFloat wantBottom,
                                       CGFloat wantRight) {
    ApolloDuoApplyInsetsToController(tabs, wantLeft, wantBottom, wantRight);
    for (UIViewController *child in tabs.viewControllers) {
        ApolloDuoApplyInsetsToController(child, wantLeft, wantBottom, wantRight);
    }
}

// Hide / Compact / portrait: zero the leading inset on the whole
// presented tree so a leftover 68pt (or a -68 cancel) cannot leave a
// white strip beside the ActionFigures feed.
static void ApolloDuoClearLeadingChromeInsets(UITabBarController *tabs,
                                              CGFloat wantBottom,
                                              CGFloat wantRight) {
    ApolloDuoWalkViewControllers(tabs, ^(UIViewController *controller) {
        ApolloDuoApplyInsetsToController(controller, 0.0, wantBottom, wantRight);
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static BOOL ApolloDuoCoverShouldApplyForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return NO;
    if (tabs.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) return NO;
    return ApolloDuoCoverChromeShouldApply(0, ApolloDuoRailDualDisplays() ? 1 : 0);
}

BOOL ApolloDuoCoverChromeIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return ApolloDuoCoverShouldApplyForTabs(tabs);
}

static BOOL ApolloDuoCoverClassLooksLikeComments(Class cls) {
    const char *name = class_getName(cls);
    return name && strstr(name, "CommentsViewController");
}

static UIView *ApolloDuoCoverFindJumpButton(UIViewController *comments) {
    Ivar ivar = class_getInstanceVariable(comments.class, "commentJumpButton");
    UIView *button = ivar ? object_getIvar(comments, ivar) : nil;
    if ([button isKindOfClass:[UIView class]]) return button;

    UIView *root = comments.view;
    if (!root) return nil;
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

void ApolloDuoCoverAdjustJumpButton(UIViewController *comments) {
    if (!comments || !ApolloDuoCoverClassLooksLikeComments(comments.class)) return;
    if (!ApolloDuoCoverChromeIsActive() || !comments.isViewLoaded) return;

    UIEdgeInsets current = comments.additionalSafeAreaInsets;
    CGFloat wantRight = (CGFloat)ApolloDuoCoverPillWidth;
    CGFloat wantBottom = (CGFloat)ApolloDuoCoverPillBottom;
    if (fabs(current.right - wantRight) > 0.5 || fabs(current.bottom - wantBottom) > 0.5) {
        comments.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, current.left,
                                                             wantBottom, wantRight);
    }

    UIView *button = ApolloDuoCoverFindJumpButton(comments);
    if (![button isKindOfClass:[UIView class]] || !button.superview) return;
    UIView *container = button.superview;
    CGRect frame = button.frame;
    CGFloat limitX = CGRectGetWidth(container.bounds) - (CGFloat)ApolloDuoCoverPillWidth;
    CGFloat limitY = CGRectGetHeight(container.bounds) - (CGFloat)ApolloDuoCoverPillBottom;
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

static UIView *ApolloDuoRailLayoutView(UIViewController *controller, UIView *container) {
    if (!controller.isViewLoaded || !container) return nil;
    UIView *view = controller.view;
    UIView *parent = view.superview;
    if (parent && parent != container && parent.superview == container) {
        return parent;
    }
    return view;
}

static void ApolloDuoRailExpandView(UIView *view, CGRect frame) {
    if (!view || CGRectGetWidth(frame) < 1.0 || CGRectGetHeight(frame) < 1.0) return;
    if (fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(frame)) < 0.5
        && fabs(CGRectGetWidth(view.frame) - CGRectGetWidth(frame)) < 0.5
        && fabs(CGRectGetHeight(view.frame) - CGRectGetHeight(frame)) < 0.5) {
        return;
    }
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.frame = frame;
}

static void ApolloDuoRailInsetHeaderView(UIView *header, CGFloat left) {
    if (!header || left < 1.0) return;
    if ([header isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hf = (UITableViewHeaderFooterView *)header;
        UIEdgeInsets margins = hf.contentView.layoutMargins;
        if (margins.left < left - 0.5) {
            margins.left = left;
            hf.contentView.layoutMargins = margins;
        }
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 40) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (![view isKindOfClass:[UILabel class]]) continue;
        UILabel *label = (UILabel *)view;
        NSString *text = [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) continue;
        CGRect frame = label.frame;
        if (CGRectGetMinX(frame) + 0.5 >= left) continue;
        frame.origin.x = left;
        frame.size.width = MAX(0.0, CGRectGetWidth(header.bounds) - left - 8.0);
        label.frame = frame;
    }
}

// Leftover Closed-overlay trim. Not applied at runtime — that
// reservation crushed section lines 88pt inland. Kept so a later
// A–Z overlay can reuse the frame-only path.
__attribute__((unused))
static void ApolloDuoRailInsetHeaderViewTrailing(UIView *header, CGFloat trailing) {
    if (!header || trailing < 1.0) return;
    CGFloat limit = CGRectGetWidth(header.bounds) - trailing;
    if (limit < 1.0) return;
    if ([header isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hf = (UITableViewHeaderFooterView *)header;
        UIEdgeInsets margins = hf.contentView.layoutMargins;
        if (margins.right < trailing - 0.5) {
            margins.right = trailing;
            hf.contentView.layoutMargins = margins;
        }
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 40) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        CGRect frame = view.frame;
        if (CGRectGetMaxX(frame) <= limit + 0.5) continue;
        BOOL hairline = CGRectGetHeight(frame) <= 2.0 && CGRectGetWidth(frame) + 0.5 >= CGRectGetWidth(header.bounds) * 0.5;
        if (![view isKindOfClass:[UILabel class]] && !hairline) continue;
        frame.size.width = MAX(0.0, limit - CGRectGetMinX(frame));
        if (fabs(frame.size.width - view.frame.size.width) < 0.5) continue;
        view.frame = frame;
    }
}

static void ApolloDuoRailApplySeparatorTrailing(UITableView *tableView, CGFloat trailing) {
    if (!tableView) return;
    UIEdgeInsets inset = tableView.separatorInset;
    NSNumber *saved = objc_getAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey);
    if (trailing > 0.5) {
        if (!saved) {
            objc_setAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey,
                                     @(inset.right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(inset.right - trailing) > 0.5) {
            inset.right = trailing;
            tableView.separatorInset = inset;
        }
    } else if (saved) {
        inset.right = saved.doubleValue;
        tableView.separatorInset = inset;
        objc_setAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloDuoRailViewIsStarOverlay(UIView *view) {
    if (!view) return NO;
    const char *name = class_getName(view.class);
    if (!name) return NO;
    return strstr(name, "StarHitProxy") != NULL
        || strstr(name, "DuoStarButton") != NULL
        || strstr(name, "DuoStarColumn") != NULL;
}

static UITableView *ApolloDuoRailTableForCell(UITableViewCell *cell) {
    for (UIView *view = cell.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    }
    return nil;
}

static UITableView *ApolloDuoRailTableFromController(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return nil;
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UITableView class]]) return (UITableView *)table;
    }
    UIView *view = controller.view;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UITableView class]]) return (UITableView *)subview;
    }
    return nil;
}

static UIControl *ApolloDuoRailNativeStarControl(UITableViewCell *cell) {
    if (!cell) return nil;
    Class listCell = NSClassFromString(@"_TtC6Apollo23RedditListTableViewCell");
    if (listCell && [cell isKindOfClass:listCell]) {
        Ivar ivar = class_getInstanceVariable(listCell, "accessoryButton");
        id value = ivar ? object_getIvar(cell, ivar) : nil;
        if ([value isKindOfClass:[UIControl class]]
            && !ApolloDuoRailViewIsStarOverlay((UIView *)value)) {
            return (UIControl *)value;
        }
    }
    if (cell.accessoryView && [cell.accessoryView isKindOfClass:[UIControl class]]
        && !ApolloDuoRailViewIsStarOverlay(cell.accessoryView)) {
        return (UIControl *)cell.accessoryView;
    }
    return nil;
}

static void ApolloDuoRailHideNativeStar(UIControl *native) {
    if (!native) return;
    if (!objc_getAssociatedObject(native, &kApolloDuoRailNativeStarHiddenKey)) {
        objc_setAssociatedObject(native, &kApolloDuoRailNativeStarHiddenKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (native.alpha > 0.0) native.alpha = 0.0;
    if (native.userInteractionEnabled) native.userInteractionEnabled = NO;
    native.isAccessibilityElement = NO;
}

static void ApolloDuoRailRestoreNativeStar(UIControl *native) {
    if (!native || !objc_getAssociatedObject(native, &kApolloDuoRailNativeStarHiddenKey)) return;
    native.alpha = 1.0;
    native.userInteractionEnabled = YES;
    native.isAccessibilityElement = YES;
    objc_setAssociatedObject(native, &kApolloDuoRailNativeStarHiddenKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoRailStripLeftoverCustomStar(UITableViewCell *cell) {
    if (!cell) return;
    NSArray<UIView *> *hosts = cell.contentView
        ? @[cell.contentView, cell]
        : @[cell];
    for (UIView *host in hosts) {
        for (UIView *subview in [host.subviews copy]) {
            const char *name = class_getName(subview.class);
            if (!name || strstr(name, "DuoStarButton") == NULL) continue;
            [subview removeFromSuperview];
        }
    }
}

static void ApolloDuoRailWindowSizeForView(UIView *view, CGFloat *outWidth, CGFloat *outHeight) {
    UIWindow *window = view.window ?: ApolloDeviceAppWindow();
    CGSize size = window ? window.bounds.size : CGSizeZero;
    if (outWidth) *outWidth = size.width;
    if (outHeight) *outHeight = size.height;
}

static void ApolloDuoRailClearRowColumnCache(UITableViewCell *cell) {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kApolloDuoRailRowMarginsResetKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowStarRetryKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowStarRetryScheduledKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLastModeKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLastContentWidthKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoRailResetStaleRowMargins(UITableViewCell *cell) {
    if (!cell) return;
    UIView *content = cell.contentView;
    if (!content) return;
    UIEdgeInsets margins = content.layoutMargins;
    CGFloat contentWidth = CGRectGetWidth(content.bounds);
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    int mode = ApolloDuoRailCurrentMode();
    NSNumber *lastModeValue = objc_getAssociatedObject(cell, &kApolloDuoRailRowLastModeKey);
    NSNumber *lastWidthValue = objc_getAssociatedObject(cell, &kApolloDuoRailRowLastContentWidthKey);
    BOOL revisit = lastModeValue
        && ApolloDuoRailRowShouldRevisitMargins(lastWidthValue ? lastWidthValue.doubleValue : 0.0,
                                                (double)contentWidth,
                                                lastModeValue.intValue,
                                                mode);
    BOOL leftoverTrailing = margins.right + 0.5 >= (CGFloat)ApolloDuoRailTableIndexFloor;
    if (objc_getAssociatedObject(cell, &kApolloDuoRailRowMarginsResetKey) && !revisit
        && !leftoverTrailing) return;
    CGFloat windowWidth = 0.0;
    CGFloat windowHeight = 0.0;
    ApolloDuoRailWindowSizeForView(cell, &windowWidth, &windowHeight);
    BOOL stale = ApolloDuoRailRowShouldDeferOpenReanchor(mode,
                                                         (double)contentWidth,
                                                         (double)cellWidth,
                                                         (double)windowWidth,
                                                         (double)windowHeight) ? YES : NO;
    if (!ApolloDuoRailRowMarginsNeedReset((double)contentWidth,
                                          (double)cellWidth,
                                          (double)margins.left,
                                          (double)ApolloDuoRailRowStockLead)
        && !leftoverTrailing) {
        if (!stale) {
            objc_setAssociatedObject(cell, &kApolloDuoRailRowMarginsResetKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    cell.preservesSuperviewLayoutMargins = YES;
    content.preservesSuperviewLayoutMargins = YES;
    // Always restore stock trailing. Leftover table-reserve writes
    // (38pt+) squeezed titles; accessoryButton ignored those margins.
    UIEdgeInsets stock = UIEdgeInsetsMake(margins.top,
                                          (CGFloat)ApolloDuoRailRowStockLead,
                                          margins.bottom,
                                          (CGFloat)ApolloDuoRailRowStockLead);
    if (fabs(cell.layoutMargins.left - stock.left) > 0.5
        || fabs(cell.layoutMargins.right - stock.right) > 0.5) {
        cell.layoutMargins = stock;
    }
    if (fabs(margins.left - stock.left) > 0.5
        || fabs(margins.right - stock.right) > 0.5) {
        content.layoutMargins = stock;
    }
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLastModeKey, @(mode),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLastContentWidthKey, @(contentWidth),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowMarginsResetKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloDuoRailSectionIndexView(UITableView *tableView) {
    if (!tableView) return nil;
    for (UIView *subview in tableView.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "TableViewIndex")) return subview;
    }
    return nil;
}

static UIView *ApolloDuoRailInstalledView(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]]) return nil;
    UIView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    if (!rail || !rail.superview || rail.hidden || rail.alpha < 0.05) return nil;
    return rail;
}

static CGFloat ApolloDuoRailWindowMinX(UIView *view) {
    if (!view) return 0.0;
    if (view.window) {
        return CGRectGetMinX([view convertRect:view.bounds toView:nil]);
    }
    return CGRectGetMinX(view.frame);
}

static void ApolloDuoRailReleaseLeadingView(UITableViewCell *cell) {
    if (!cell || !objc_getAssociatedObject(cell, &kApolloDuoRailRowLeadingClaimedKey)) return;
    NSArray<NSLayoutConstraint *> *disabled =
        objc_getAssociatedObject(cell, &kApolloDuoRailRowDisabledConstraintsKey);
    for (NSLayoutConstraint *constraint in disabled) {
        if (constraint) constraint.active = YES;
    }
    objc_setAssociatedObject(cell, &kApolloDuoRailRowDisabledConstraintsKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLeadingClaimedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloDuoRailPrepareSubredditRow(UITableViewCell *cell) {
    if (!cell) return;
    int mode = ApolloDuoRailCurrentMode();
    if (!ApolloDuoRailRowPolishShouldApply(mode)) return;
    ApolloDuoRailResetStaleRowMargins(cell);
}

void ApolloDuoRailHideNativeStarInRow(UITableViewCell *cell) {
    if (!cell) return;
    if (!ApolloDuoRailStarColumnShouldApply(ApolloDuoRailCurrentMode())) return;
    if (cell.editing) return;
    const char *name = class_getName(cell.class);
    if (name && strstr(name, "ApolloSubtitleTableViewCell")) return;
    ApolloDuoRailHideNativeStar(ApolloDuoRailNativeStarControl(cell));
    ApolloDuoRailStripLeftoverCustomStar(cell);
}

void ApolloDuoRailResetSubredditRowReuse(UITableViewCell *cell) {
    if (!cell) return;
    ApolloDuoRailStripLeftoverCustomStar(cell);
    if (ApolloDuoRailStarColumnShouldApply(ApolloDuoRailCurrentMode())) {
        ApolloDuoRailHideNativeStar(ApolloDuoRailNativeStarControl(cell));
    } else {
        ApolloDuoRailRestoreNativeStar(ApolloDuoRailNativeStarControl(cell));
    }
    ApolloDuoRailClearRowColumnCache(cell);
    ApolloDuoRailReleaseLeadingView(cell);
}

void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell) {
    if (!cell) return;
    ApolloDuoRailReleaseLeadingView(cell);
    ApolloDuoRailStripLeftoverCustomStar(cell);
    const char *name = class_getName(cell.class);
    if (name && strstr(name, "ApolloSubtitleTableViewCell")) {
        ApolloDuoRailRestoreNativeStar(ApolloDuoRailNativeStarControl(cell));
        return;
    }
    UITableView *table = ApolloDuoRailTableForCell(cell);
    if (table && table.cellLayoutMarginsFollowReadableWidth) {
        table.cellLayoutMarginsFollowReadableWidth = NO;
    }
    if (!ApolloDuoRailStarColumnShouldApply(ApolloDuoRailCurrentMode()) || cell.editing) {
        ApolloDuoRailRestoreNativeStar(ApolloDuoRailNativeStarControl(cell));
        return;
    }
    ApolloDuoRailHideNativeStar(ApolloDuoRailNativeStarControl(cell));
}

static BOOL ApolloDuoRailTableLooksLikeRedditList(UITableView *tableView) {
    if (!tableView) return NO;
    for (UITableViewCell *cell in tableView.visibleCells) {
        const char *name = class_getName(cell.class);
        if (name && strstr(name, "RedditListTableViewCell")) return YES;
    }
    UIViewController *controller = nil;
    UIResponder *responder = tableView.nextResponder;
    while (responder && !controller) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            controller = (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    const char *vcName = controller ? class_getName(controller.class) : NULL;
    return vcName && strstr(vcName, "RedditListViewController") != NULL;
}

@interface ApolloDuoStarColumnView : UIView
@property (nonatomic, weak) UITableView *tableView;
@end

@implementation ApolloDuoStarColumnView
@end

@interface ApolloDuoStarColumnButton : UIButton
@property (nonatomic, weak) UIControl *nativeControl;
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSIndexPath *indexPath;
@end

@implementation ApolloDuoStarColumnButton
- (void)apollo_duoStarColumnTapped {
    UIControl *native = self.nativeControl;
    if (!native) return;
    ApolloLog(@"[ApolloDuoStar] overlay tap name=%@ native=%@",
              self.subredditName ?: @"(unknown)",
              NSStringFromClass(native.class));
    [native sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

static NSString *ApolloDuoRailCellTitle(UITableViewCell *cell) {
    if (!cell) return nil;
    if (cell.textLabel.text.length > 0) return cell.textLabel.text;
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    if (cell.contentView) [stack addObject:cell.contentView];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 24) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)candidate;
            if (label.text.length > 0) return label.text;
        }
        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }
    return nil;
}

static BOOL ApolloDuoRailNameIsFavorite(NSString *name) {
    if (name.length == 0) return NO;
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"FavoriteSubreddits"];
    if (![favorites isKindOfClass:[NSArray class]]) return NO;
    for (id value in favorites) {
        if (![value isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)value caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL ApolloDuoRailCellLooksFavorited(UITableViewCell *cell, UIControl *native, NSString *name) {
    if (ApolloDuoRailNameIsFavorite(name)) return YES;
    if ([native isKindOfClass:[UIButton class]] && ((UIButton *)native).selected) return YES;
    UITableView *table = ApolloDuoRailTableForCell(cell);
    NSIndexPath *path = table ? [table indexPathForCell:cell] : nil;
    if (path && [table numberOfSections] > 0) {
        NSArray *titles = nil;
        if ([table.dataSource respondsToSelector:@selector(sectionIndexTitlesForTableView:)]) {
            titles = [table.dataSource sectionIndexTitlesForTableView:table];
        }
        if (titles.count > 0 && path.section < (NSInteger)titles.count) {
            NSString *title = titles[path.section];
            if ([title isEqualToString:@"★"] || [title isEqualToString:@"*"]) return YES;
        }
    }
    return NO;
}

static UIView *ApolloDuoRailIndexOverlayView(UITableView *tableView) {
    UIView *container = tableView.superview;
    if (!container) return nil;
    for (UIView *subview in container.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "SubredditIndexOverlay")) return subview;
    }
    return nil;
}

static void ApolloDuoRailMeasureIndex(UITableView *tableView,
                                     CGFloat *outWidth,
                                     CGFloat *outLeading) {
    if (outWidth) *outWidth = 0.0;
    if (outLeading) *outLeading = 0.0;
    if (!tableView) return;
    CGFloat tableWidth = CGRectGetWidth(tableView.bounds);
    CGFloat width = 0.0;
    CGFloat leading = 0.0;
    UIView *native = ApolloDuoRailSectionIndexView(tableView);
    if (native && !native.hidden && CGRectGetWidth(native.bounds) > 0.5) {
        CGRect inTable = [tableView convertRect:native.bounds fromView:native];
        width = CGRectGetWidth(inTable);
        leading = CGRectGetMinX(inTable);
    }
    UIView *overlay = ApolloDuoRailIndexOverlayView(tableView);
    if (overlay && !overlay.hidden && CGRectGetWidth(overlay.bounds) > 0.5) {
        CGRect inTable = [tableView convertRect:overlay.bounds fromView:overlay];
        CGFloat overlayWidth = CGRectGetWidth(inTable);
        CGFloat overlayLeading = CGRectGetMinX(inTable);
        if (overlayWidth > width) width = overlayWidth;
        if (leading < 0.5 || (overlayLeading > 0.5 && overlayLeading < leading)) {
            leading = overlayLeading;
        }
    }
    if (width < 0.5 && tableWidth > 0.5) {
        width = (CGFloat)ApolloDuoRailClosedIndexWidth;
        leading = tableWidth - width;
    }
    if (outWidth) *outWidth = width;
    if (outLeading) *outLeading = leading;
}

static BOOL ApolloDuoRailViewLooksLikeFloatingPill(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05) return NO;
    const char *name = class_getName(view.class);
    if (!name) return NO;
    return strstr(name, "FloatingTabBar") != NULL
        || strstr(name, "TabContainer") != NULL;
}

static CGFloat ApolloDuoRailMeasurePillOverlap(UITableView *tableView) {
    if (!tableView) return 0.0;
    CGFloat tableWidth = CGRectGetWidth(tableView.bounds);
    if (tableWidth < 1.0) return 0.0;
    CGFloat overlap = 0.0;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    UIView *rail = ApolloDuoRailInstalledView();
    if (rail) [candidates addObject:rail];
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    UIView *root = tabs.isViewLoaded ? tabs.view : nil;
    if (root) {
        for (UIView *subview in root.subviews) {
            if (ApolloDuoRailViewLooksLikeFloatingPill(subview)) {
                [candidates addObject:subview];
            }
            for (UIView *child in subview.subviews) {
                if (ApolloDuoRailViewLooksLikeFloatingPill(child)) {
                    [candidates addObject:child];
                }
            }
        }
    }
    for (UIView *view in candidates) {
        CGRect inTable = [tableView convertRect:view.bounds fromView:view];
        CGFloat pill = (CGFloat)ApolloDuoRailTablePillOverlap(tableWidth,
                                                             CGRectGetMinX(inTable),
                                                             CGRectGetWidth(inTable));
        if (pill > overlap) overlap = pill;
    }
    return overlap;
}

static void ApolloDuoRailRemoveStarColumn(UITableView *tableView);

static void ApolloDuoRailStripLeftoverTableReserve(UITableView *tableView) {
    if (!tableView) return;
    CGFloat stock = (CGFloat)ApolloDuoRailRowStockLead;
    CGFloat floor = (CGFloat)ApolloDuoRailTableIndexFloor;
    UIEdgeInsets margins = tableView.layoutMargins;
    if (margins.right + 0.5 >= floor) {
        margins.right = stock;
        tableView.layoutMargins = margins;
    }
    NSDirectionalEdgeInsets dir = tableView.directionalLayoutMargins;
    if (dir.trailing + 0.5 >= floor) {
        dir.trailing = stock;
        tableView.directionalLayoutMargins = dir;
    }
}

static void ApolloDuoRailRestoreTableTrailing(UITableView *tableView) {
    if (!tableView) return;
    ApolloDuoRailStripLeftoverTableReserve(tableView);
    ApolloDuoRailRemoveStarColumn(tableView);
}

static ApolloDuoStarColumnView *ApolloDuoRailStarColumn(UITableView *tableView, BOOL create) {
    ApolloDuoStarColumnView *column = objc_getAssociatedObject(tableView, &kApolloDuoRailStarColumnKey);
    if (column || !create) return column;
    UIView *container = tableView.superview;
    if (!container) return nil;
    column = [[ApolloDuoStarColumnView alloc] initWithFrame:CGRectZero];
    column.tableView = tableView;
    column.userInteractionEnabled = YES;
    column.backgroundColor = UIColor.clearColor;
    objc_setAssociatedObject(tableView, &kApolloDuoRailStarColumnKey, column,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:column];
    return column;
}

static void ApolloDuoRailRemoveStarColumn(UITableView *tableView) {
    UIView *column = objc_getAssociatedObject(tableView, &kApolloDuoRailStarColumnKey);
    if (!column) return;
    [column removeFromSuperview];
    objc_setAssociatedObject(tableView, &kApolloDuoRailStarColumnKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UITableViewCell *cell in tableView.visibleCells) {
        ApolloDuoRailRestoreNativeStar(ApolloDuoRailNativeStarControl(cell));
    }
}

static void ApolloDuoRailSyncStarColumn(UITableView *tableView) {
    if (!tableView) return;
    int mode = ApolloDuoRailCurrentMode();
    if (!ApolloDuoRailStarColumnShouldApply(mode)
        || tableView.editing
        || !ApolloDuoRailTableLooksLikeRedditList(tableView)) {
        ApolloDuoRailRestoreTableTrailing(tableView);
        return;
    }
    ApolloDuoRailStripLeftoverTableReserve(tableView);

    CGFloat tableWidth = CGRectGetWidth(tableView.bounds);
    CGFloat indexWidth = 0.0;
    CGFloat indexLeading = 0.0;
    ApolloDuoRailMeasureIndex(tableView, &indexWidth, &indexLeading);
    CGFloat pillLeading = 0.0;
    CGFloat pillOverlap = ApolloDuoRailMeasurePillOverlap(tableView);
    if (pillOverlap > 0.5) {
        pillLeading = tableWidth - pillOverlap;
    }
    CGFloat guide = (CGFloat)ApolloDuoRailStarColumnGuideLeading((double)indexLeading,
                                                                (double)pillLeading);
    CGFloat columnMaxX = (CGFloat)ApolloDuoRailStarColumnResolvedMaxX((double)guide,
                                                                     (double)tableWidth,
                                                                     (double)indexWidth,
                                                                     (double)ApolloDuoRailRowStarIndexGap);
    if (columnMaxX < 0.5) {
        ApolloDuoRailRemoveStarColumn(tableView);
        return;
    }

    ApolloDuoStarColumnView *column = ApolloDuoRailStarColumn(tableView, YES);
    if (!column) return;
    UIView *container = tableView.superview;
    if (!container) return;
    if (column.superview != container) {
        [column removeFromSuperview];
        [container addSubview:column];
    }
    CGRect tableFrame = [container convertRect:tableView.bounds fromView:tableView];
    CGFloat hit = (CGFloat)ApolloDuoRailRowStarButtonHit;
    CGFloat hostMinX = (CGFloat)ApolloDuoRailStarColumnHostMinX((double)columnMaxX, (double)hit);
    CGRect want = CGRectMake(CGRectGetMinX(tableFrame) + hostMinX,
                             CGRectGetMinY(tableFrame),
                             hit,
                             CGRectGetHeight(tableFrame));
    if (ApolloDuoRailStarColumnNeedsMove((double)column.frame.origin.x, (double)want.origin.x)
        || ApolloDuoRailStarColumnNeedsMove((double)column.frame.origin.y, (double)want.origin.y)
        || ApolloDuoRailTableReserveNeedsUpdate((double)column.frame.size.width, (double)want.size.width)
        || ApolloDuoRailTableReserveNeedsUpdate((double)column.frame.size.height, (double)want.size.height)) {
        column.frame = want;
        ApolloLog(@"[ApolloDuoStar] overlay column x=%.1f maxX=%.1f guide=%.1f indexLead=%.1f pillLead=%.1f",
                  want.origin.x, columnMaxX, guide, indexLeading, pillLeading);
    }
    UIView *indexOverlay = ApolloDuoRailIndexOverlayView(tableView);
    if (indexOverlay && indexOverlay.superview == container) {
        [container insertSubview:column belowSubview:indexOverlay];
    } else {
        [container bringSubviewToFront:column];
    }

    NSMutableArray<ApolloDuoStarColumnButton *> *pool = [NSMutableArray array];
    for (UIView *subview in [column.subviews copy]) {
        if ([subview isKindOfClass:[ApolloDuoStarColumnButton class]]) {
            [pool addObject:(ApolloDuoStarColumnButton *)subview];
        } else {
            [subview removeFromSuperview];
        }
    }
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *outline = [UIImage systemImageNamed:@"star" withConfiguration:config];
    UIImage *filledImage = [UIImage systemImageNamed:@"star.fill" withConfiguration:config];
    NSInteger used = 0;
    for (UITableViewCell *cell in tableView.visibleCells) {
        const char *cls = class_getName(cell.class);
        if (cls && strstr(cls, "ApolloSubtitleTableViewCell")) continue;
        UIControl *native = ApolloDuoRailNativeStarControl(cell);
        if (!native) continue;
        ApolloDuoRailHideNativeStar(native);
        NSIndexPath *path = [tableView indexPathForCell:cell];
        NSString *name = ApolloDuoRailCellTitle(cell);
        ApolloDuoStarColumnButton *button = nil;
        for (NSInteger i = 0; i < (NSInteger)pool.count; i++) {
            ApolloDuoStarColumnButton *candidate = pool[i];
            if (path && [candidate.indexPath isEqual:path]) {
                button = candidate;
                [pool removeObjectAtIndex:i];
                break;
            }
        }
        if (!button && pool.count > 0) {
            button = pool.firstObject;
            [pool removeObjectAtIndex:0];
        }
        if (!button) {
            button = [ApolloDuoStarColumnButton buttonWithType:UIButtonTypeSystem];
            button.adjustsImageWhenHighlighted = NO;
            button.adjustsImageWhenDisabled = NO;
            button.tintColor = [UIColor tertiaryLabelColor];
            [button addTarget:button action:@selector(apollo_duoStarColumnTapped)
             forControlEvents:UIControlEventTouchUpInside];
            [column addSubview:button];
        }
        button.nativeControl = native;
        button.subredditName = name;
        button.indexPath = path;
        BOOL filled = ApolloDuoRailCellLooksFavorited(cell, native, name);
        [button setImage:filled ? filledImage : outline forState:UIControlStateNormal];
        button.accessibilityLabel = filled ? @"Unfavorite" : @"Favorite";
        CGRect cellInColumn = [column convertRect:cell.bounds fromView:cell];
        CGFloat midY = CGRectGetMidY(cellInColumn);
        CGRect buttonFrame = CGRectMake(0.0, midY - hit * 0.5, hit, hit);
        if (ApolloDuoRailStarColumnNeedsMove((double)button.frame.origin.y, (double)buttonFrame.origin.y)
            || ApolloDuoRailTableReserveNeedsUpdate((double)button.frame.size.height,
                                                    (double)buttonFrame.size.height)) {
            button.frame = buttonFrame;
        } else if (CGRectGetWidth(button.frame) < 1.0) {
            button.frame = buttonFrame;
        }
        button.hidden = NO;
        used += 1;
    }
    for (ApolloDuoStarColumnButton *leftover in pool) {
        leftover.nativeControl = nil;
        leftover.subredditName = nil;
        leftover.indexPath = nil;
        [leftover removeFromSuperview];
    }
    if (used == 0) {
        ApolloLog(@"[ApolloDuoStar] overlay column x=%.1f (no starred rows yet)",
                  CGRectGetMaxX(want));
    }
}

static void ApolloDuoRailApplyStarColumn(UITableView *tableView) {
    if (!tableView) return;
    if (tableView.cellLayoutMarginsFollowReadableWidth) {
        tableView.cellLayoutMarginsFollowReadableWidth = NO;
    }
    for (UITableViewCell *cell in tableView.visibleCells) {
        ApolloDuoRailPrepareSubredditRow(cell);
        ApolloDuoRailTightenSubredditRow(cell);
    }
    ApolloDuoRailSyncStarColumn(tableView);
}

static void ApolloDuoRailScheduleDeferredReanchor(UITableView *tableView, BOOL shouldDefer) {
    if (!tableView) return;
    if (!ApolloDuoRailRowShouldScheduleDeferredForce(sApolloDuoRailDeferredScheduled ? 1 : 0,
                                                     sApolloDuoRailDeferredAttempt,
                                                     1,
                                                     shouldDefer ? 1 : 0)) {
        if (!shouldDefer) sApolloDuoRailDeferredAttempt = 0;
        return;
    }
    sApolloDuoRailDeferredScheduled = YES;
    __weak UITableView *weakTable = tableView;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloDuoRailDeferredScheduled = NO;
        sApolloDuoRailDeferredAttempt += 1;
        UITableView *strongTable = weakTable;
        if (strongTable) {
            ApolloDuoRailReanchorSubredditStars(strongTable, YES);
        }
    });
}

void ApolloDuoRailReanchorSubredditStars(UITableView *tableView, BOOL forceLayout) {
    if (!tableView) return;
    int mode = ApolloDuoRailCurrentMode();
    if (!ApolloDuoRailStarColumnShouldApply(mode)) {
        ApolloDuoRailRestoreTableTrailing(tableView);
        return;
    }
    if (!ApolloDuoRailTableLooksLikeRedditList(tableView)) return;

    if (sApolloDuoRailLastReanchorMode >= 0
        && ApolloDuoRailRowShouldClearCachedColumn(1, sApolloDuoRailLastReanchorMode, mode)) {
        for (UITableViewCell *cell in tableView.visibleCells) {
            ApolloDuoRailResetSubredditRowReuse(cell);
        }
        ApolloDuoRailRemoveStarColumn(tableView);
        sApolloDuoRailDeferredAttempt = 0;
    }
    sApolloDuoRailLastReanchorMode = mode;

    ApolloDuoRailApplyStarColumn(tableView);
    if (forceLayout) {
        ApolloDuoRailScheduleDeferredReanchor(tableView, 0);
    } else {
        ApolloDuoRailReanchorVisibleStarsAfterLayout(tableView);
    }
}

void ApolloDuoRailReanchorVisibleStars(UITableView *tableView) {
    ApolloDuoRailApplyStarColumn(tableView);
}

void ApolloDuoRailRefreshVisibleStars(UITableView *tableView) {
    ApolloDuoRailSyncStarColumn(tableView);
}

void ApolloDuoRailReanchorVisibleStarsAfterLayout(UITableView *tableView) {
    if (!tableView) return;
    if (!ApolloDuoRailRowPolishShouldApply(ApolloDuoRailCurrentMode())) return;
    if (!ApolloDuoRailTableLooksLikeRedditList(tableView)) return;
    if (!ApolloDuoRailRowShouldScheduleAfterLayoutPass(sApolloDuoRailAfterLayoutScheduled ? 1 : 0)) {
        return;
    }
    sApolloDuoRailAfterLayoutScheduled = YES;
    __weak UITableView *weakTable = tableView;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloDuoRailAfterLayoutScheduled = NO;
        UITableView *strongTable = weakTable;
        if (!strongTable) return;
        ApolloDuoRailReanchorVisibleStars(strongTable);
    });
}

void ApolloDuoRailPolishSubredditList(UITableView *tableView) {
    ApolloDuoRailReanchorSubredditStars(tableView, NO);
}

void ApolloDuoRailReanchorRedditList(UIViewController *controller, BOOL forceLayout) {
    if (!controller) return;
    const char *name = class_getName(controller.class);
    if (!name || !strstr(name, "RedditListViewController")) return;
    UITableView *table = ApolloDuoRailTableFromController(controller);
    if (table) ApolloDuoRailReanchorSubredditStars(table, forceLayout);
}

static void ApolloDuoRailReanchorCurrentList(BOOL forceLayout) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]]) return;
    UINavigationController *nav = ApolloDuoRailNavFromController(tabs.selectedViewController);
    if (!nav) nav = ApolloDuoRailFindPostsNav(tabs, NO);
    ApolloDuoRailReanchorRedditList(nav.topViewController, forceLayout);
}

static void ApolloDuoRailReanchorCurrentListSoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoRailReanchorCurrentList(YES);
    });
}

static void ApolloDuoRailApplyScrollInsetLeft(UIScrollView *scrollView, CGFloat left) {
    if (!scrollView) return;
    UIEdgeInsets inset = scrollView.contentInset;
    NSNumber *saved = objc_getAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey);
    if (left > 0.5) {
        if (!saved) {
            objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey,
                                     @(inset.left), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(inset.left - left) > 0.5) {
            inset.left = left;
            scrollView.contentInset = inset;
        }
    } else if (saved) {
        inset.left = saved.doubleValue;
        scrollView.contentInset = inset;
        objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloDuoRailScrollViewIsTexture(UIScrollView *scrollView) {
    if (!scrollView) return NO;
    const char *name = class_getName(scrollView.class);
    return name && strstr(name, "ASTable");
}

static UIScrollView *ApolloDuoRailFindPrimaryTable(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:[UIScrollView class]]
        && ([view isKindOfClass:[UITableView class]] || ApolloDuoRailScrollViewIsTexture((UIScrollView *)view))) {
        return (UIScrollView *)view;
    }
    UIScrollView *best = nil;
    for (UIView *subview in view.subviews) {
        UIScrollView *found = ApolloDuoRailFindPrimaryTable(subview, depth - 1);
        if (!found) continue;
        if (ApolloDuoRailScrollViewIsTexture(found)) return found;
        if (!best) best = found;
    }
    return best;
}

// Shift a full-bleed Texture / UIKit table so its window minX is the
// content inset. No-op when already clear. Frame write (not contentInset)
// is what Texture honors — ASDK cells ignore additionalSafeAreaInsets.
static BOOL ApolloDuoRailShiftScrollViewOffRail(UIScrollView *scrollView) {
    if (!scrollView || !scrollView.superview || !ApolloDuoRailIsActive()) return NO;
    CGFloat inset = (CGFloat)ApolloDuoRailContentLeftInset();
    CGRect frame = scrollView.frame;
    CGRect want = frame;
    if (ApolloDuoRailIsLeading()) {
        CGFloat windowX = ApolloDuoRailWindowMinX(scrollView);
        if (windowX + 0.5 >= inset) return NO;
        CGFloat bump = inset - windowX;
        want.origin.x += bump;
        want.size.width = MAX(0.0, want.size.width - bump);
    } else {
        // Closed overlays the rail. Shrinking the table by ~120pt is
        // the Image 1 crush — leave the scroll view full-bleed.
        return NO;
    }
    if (fabs(want.origin.x - frame.origin.x) < 0.5
        && fabs(want.size.width - frame.size.width) < 0.5) {
        return NO;
    }
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.frame = want;
    return YES;
}

void ApolloDuoRailApplyListInsets(UIScrollView *scrollView) {
    if (!scrollView) return;
    BOOL active = ApolloDuoRailIsActive();
    if (active && ApolloDuoRailScrollViewIsTexture(scrollView)) {
        // Texture paints cells to the table bounds, not the safe area.
        // Shift the ASTableView itself so vote chevrons clear the rail.
        ApolloDuoRailShiftScrollViewOffRail(scrollView);
    }
    CGFloat windowX = ApolloDuoRailWindowMinX(scrollView);
    BOOL underRail = active && ApolloDuoRailIsLeading()
        && (windowX + 0.5 < (CGFloat)ApolloDuoRailContentLeftInset());
    // UIKit RedditList cells already honor the nav safe-area inset.
    // Do not stack contentInset.left on those — that was the portrait
    // white strip. Texture got a frame shift above instead.
    ApolloDuoRailApplyScrollInsetLeft(scrollView, 0.0);

    if (![scrollView isKindOfClass:[UITableView class]]) return;
    UITableView *tableView = (UITableView *)scrollView;
    if (!active) {
        ApolloDuoRailApplySeparatorTrailing(tableView, 0.0);
        ApolloDuoRailPolishSubredditList(tableView);
        return;
    }

    if (tableView.cellLayoutMarginsFollowReadableWidth) {
        tableView.cellLayoutMarginsFollowReadableWidth = NO;
    }
    CGFloat headerLeft = underRail
        ? ((CGFloat)ApolloDuoRailContentLeftInset() - MAX(windowX, 0.0))
        : 0.0;
    // Full-width section lines. Do not reserve the removed Closed
    // overlay rail (that parked FAVORITES / MODERATOR / A 88pt inland).
    ApolloDuoRailApplySeparatorTrailing(tableView, 0.0);
    if (headerLeft > 0.5) {
        NSInteger sections = tableView.numberOfSections;
        for (NSInteger section = 0; section < sections && section < 24; section++) {
            UIView *header = [tableView headerViewForSection:section];
            if (header) ApolloDuoRailInsetHeaderView(header, headerLeft);
        }
        for (UIView *subview in tableView.subviews) {
            const char *name = class_getName(subview.class);
            if (name && strstr(name, "Header")) {
                ApolloDuoRailInsetHeaderView(subview, headerLeft);
            }
        }
    }
    ApolloDuoRailPolishSubredditList(tableView);
}

static void ApolloDuoRailFillController(UIViewController *controller, UIView *container) {
    if (!controller || !container || CGRectGetWidth(container.bounds) < 1.0) return;
    if (!controller.isViewLoaded) return;
    CGFloat containerWidth = CGRectGetWidth(container.bounds);
    CGFloat containerHeight = CGRectGetHeight(container.bounds);
    int mode = ApolloDuoRailCurrentMode();
    ApolloDuoRailRect want = ApolloDuoRailContentFrameInBoundsForMode(containerWidth,
                                                                     containerHeight,
                                                                     mode);
    CGRect wantFrame = CGRectMake(want.x, want.y, want.width, want.height);
    BOOL expanded = NO;
    UIView *view = controller.view;
    BOOL texture = NO;
    UIScrollView *existingTable = ApolloDuoRailFindPrimaryTable(view, 5);
    if (existingTable) texture = ApolloDuoRailScrollViewIsTexture(existingTable);
    // Full-bleed UIKit lists (RedditList) stay full-width and use the
    // nav's additionalSafeAreaInsets for cells — a frame shift here is
    // undone on scroll. Only letterboxed phone columns and Texture
    // feeds are moved to the content frame.
    UIView *layout = ApolloDuoRailLayoutView(controller, container);
    BOOL letterboxed = layout
        ? ApolloDuoRailContentIsLetterboxed(layout.frame.size.width, containerWidth)
        : NO;
    BOOL needsClearance = letterboxed || texture;
    if (needsClearance && layout && ApolloDuoModeIsLeading(mode)) {
        needsClearance = ApolloDuoRailContentNeedsLeadingClearance(layout.frame.origin.x,
                                                                  layout.frame.size.width,
                                                                  containerWidth);
    }
    if (layout && layout != container
        && needsClearance) {
        ApolloLog(@"[DuoRail] filled %@ x=%.0f w=%.0f → x=%.0f w=%.0f",
                  NSStringFromClass(controller.class),
                  layout.frame.origin.x, layout.frame.size.width, want.x, want.width);
        ApolloDuoRailExpandView(layout, wantFrame);
        expanded = YES;
    }
    letterboxed = view
        ? ApolloDuoRailContentIsLetterboxed(view.frame.size.width, containerWidth)
        : letterboxed;
    BOOL viewNeedsClearance = letterboxed || texture;
    if (viewNeedsClearance && ApolloDuoModeIsLeading(mode)) {
        viewNeedsClearance = ApolloDuoRailContentNeedsLeadingClearance(view.frame.origin.x,
                                                                      view.frame.size.width,
                                                                      containerWidth);
    }
    if (view && view != layout && view != container
        && viewNeedsClearance) {
        ApolloDuoRailExpandView(view, layout && layout != view ? layout.bounds : wantFrame);
        expanded = YES;
    }
    if (view) {
        CGSize preferred = controller.preferredContentSize;
        if (want.width > 0.5 && preferred.width + (CGFloat)ApolloDuoRailLetterboxGap < want.width) {
            if (!objc_getAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey)) {
                objc_setAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey,
                                         [NSValue valueWithCGSize:preferred],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controller.preferredContentSize = CGSizeMake((CGFloat)want.width, preferred.height);
        }
    }
    if (controller.isViewLoaded) {
        // Never cancel inherited leading safe-area on UIKit lists. A
        // one-shot table/VC frame shift is undone on scroll, and the
        // leftover additionalSafeAreaInsets.left = -80 was why rows
        // slid under the rail while headers (separate path) stayed put.
        UIEdgeInsets extra = controller.additionalSafeAreaInsets;
        if (extra.left < -0.5) {
            extra.left = 0.0;
            controller.additionalSafeAreaInsets = extra;
        }
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIScrollView class]]) {
            UIView *tableParent = table.superview ?: view;
            CGFloat parentWidth = tableParent ? CGRectGetWidth(tableParent.bounds) : containerWidth;
            CGFloat parentHeight = tableParent ? CGRectGetHeight(tableParent.bounds) : containerHeight;
            BOOL tableTexture = ApolloDuoRailScrollViewIsTexture((UIScrollView *)table);
            BOOL tableLetterboxed = ApolloDuoRailContentIsLetterboxed(table.frame.size.width, parentWidth);
            BOOL tableNeedsClearance = tableTexture || tableLetterboxed;
            if (tableNeedsClearance && ApolloDuoModeIsLeading(mode)) {
                tableNeedsClearance = ApolloDuoRailContentNeedsLeadingClearance(table.frame.origin.x,
                                                                               table.frame.size.width,
                                                                               parentWidth);
            }
            if (tableParent == container
                && tableNeedsClearance) {
                ApolloDuoRailExpandView(table, wantFrame);
                expanded = YES;
            } else if (tableParent != container
                       && tableLetterboxed) {
                table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                table.frame = CGRectMake(0.0, 0.0, parentWidth, parentHeight);
                expanded = YES;
            }
            ApolloDuoRailApplyListInsets((UIScrollView *)table);
        }
    }
    id tableNode = nil;
    Ivar nodeIvar = class_getInstanceVariable(controller.class, "tableNode");
    if (!nodeIvar) nodeIvar = class_getInstanceVariable(controller.class, "_tableNode");
    if (nodeIvar) tableNode = object_getIvar(controller, nodeIvar);
    if (tableNode) {
        UIView *nodeView = nil;
        if ([tableNode respondsToSelector:@selector(view)]) {
            nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        }
        if ([nodeView isKindOfClass:[UIScrollView class]]) {
            if (ApolloDuoRailShiftScrollViewOffRail((UIScrollView *)nodeView)) {
                expanded = YES;
            }
            ApolloDuoRailApplyListInsets((UIScrollView *)nodeView);
        }
        if (expanded) {
            if ([tableNode respondsToSelector:@selector(setNeedsLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(setNeedsLayout));
            }
            if ([tableNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(invalidateCalculatedLayout));
            }
            if ([tableNode respondsToSelector:@selector(relayoutItems)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(relayoutItems));
            }
        }
    }
    UIScrollView *found = ApolloDuoRailFindPrimaryTable(view ?: layout, 5);
    if (found) {
        if (ApolloDuoRailScrollViewIsTexture(found)
            && ApolloDuoRailShiftScrollViewOffRail(found)) {
            expanded = YES;
        }
        ApolloDuoRailApplyListInsets(found);
    }
}

void ApolloDuoRailFillOpenContent(void) {
    if (!ApolloDuoRailIsActive()) return;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;
    UINavigationController *nav = ApolloDuoRailNavFromController(tabs.selectedViewController);
    if (!nav) nav = ApolloDuoRailFindPostsNav(tabs, NO);
    if (!nav.isViewLoaded) return;
    // Keep the nav (and its bar) full-width so "Subreddits" stays centered.
    UIView *container = nav.view ?: tabs.view;
    UIViewController *top = nav.topViewController;
    if (top) ApolloDuoRailFillController(top, container);
}

static void ApolloDuoRailRestoreController(UIViewController *controller, UIView *container) {
    if (!controller) return;
    NSValue *savedSize = objc_getAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey);
    if (savedSize) {
        controller.preferredContentSize = savedSize.CGSizeValue;
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *savedLeft = objc_getAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey);
    if (savedLeft) {
        UIEdgeInsets extra = controller.additionalSafeAreaInsets;
        extra.left = savedLeft.doubleValue;
        controller.additionalSafeAreaInsets = extra;
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!controller.isViewLoaded) return;
    UIView *layout = ApolloDuoRailLayoutView(controller, container ?: controller.view.superview);
    if (layout && layout.superview) {
        ApolloDuoRailExpandView(layout, layout.superview.bounds);
    }
    if (controller.view != layout && controller.view.superview) {
        ApolloDuoRailExpandView(controller.view, controller.view.superview.bounds);
    }
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIScrollView class]]) {
            ApolloDuoRailApplyScrollInsetLeft((UIScrollView *)table, 0.0);
            if ([table isKindOfClass:[UITableView class]]) {
                ApolloDuoRailApplySeparatorTrailing((UITableView *)table, 0.0);
                ApolloDuoRailRestoreTableTrailing((UITableView *)table);
            }
            if (table.superview) {
                ApolloDuoRailExpandView(table, table.superview.bounds);
            }
        }
    }
    UIScrollView *found = controller.isViewLoaded
        ? ApolloDuoRailFindPrimaryTable(controller.view, 5) : nil;
    if (found && found.superview) {
        ApolloDuoRailApplyScrollInsetLeft(found, 0.0);
        if ([found isKindOfClass:[UITableView class]]) {
            ApolloDuoRailApplySeparatorTrailing((UITableView *)found, 0.0);
            ApolloDuoRailRestoreTableTrailing((UITableView *)found);
        }
        ApolloDuoRailExpandView(found, found.superview.bounds);
    }
}

void ApolloDuoRailClearOpenContent(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = ApolloDuoRailNavFromController(child);
        if (!nav) {
            ApolloDuoRailRestoreController(child, child.view.superview);
            continue;
        }
        UIView *container = nav.isViewLoaded ? nav.view : nil;
        for (UIViewController *controller in nav.viewControllers) {
            ApolloDuoRailRestoreController(controller, container);
        }
    }
}

BOOL ApolloDuoRailIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];
}

void ApolloDuoRailSync(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;

    int mode = ApolloDuoRailModeForTabs(tabs);
    BOOL show = mode == ApolloDuoModeOpen;
    ApolloDuoRailView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];
    int previousMode = [objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey) intValue];

    if (!show) {
        if (rail.superview) [rail removeFromSuperview];
        ApolloDuoClearLeadingChromeInsets(tabs, 0.0, 0.0);
        ApolloDuoRailClearOpenContent();
        ApolloDuoRailSetTabBarHidden(tabs, NO);
        objc_setAssociatedObject(tabs, &kApolloDuoRailModeKey, @(mode),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (wasActive) {
            objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoRail] hidden; stock tab bar restored (mode=%d)", mode);
        }
        ApolloDuoSubsChromeApplyToTabs(tabs);
        if (wasActive || previousMode != mode) {
            ApolloDuoRailReanchorCurrentListSoon();
        }
        return;
    }

    if (!rail) {
        rail = [[ApolloDuoRailView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(tabs, &kApolloDuoRailViewKey, rail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL leading = ApolloDuoModeIsLeading(mode);
    rail.leading = leading;
    CGRect bounds = tabs.view.bounds;
    UIEdgeInsets safe = ApolloDuoRailSystemSafeInsets(tabs);
    ApolloDuoRailRect frame = ApolloDuoRailFrameInBoundsOnSide(bounds.size.width,
                                                              bounds.size.height,
                                                              safe.top,
                                                              safe.bottom,
                                                              0.0,
                                                              leading ? 1 : 0);
    rail.autoresizingMask = UIViewAutoresizingFlexibleHeight
        | (leading ? UIViewAutoresizingFlexibleRightMargin
                   : UIViewAutoresizingFlexibleLeftMargin);
    CGRect nextFrame = CGRectMake(frame.x, frame.y, frame.width, frame.height);
    if (fabs(rail.frame.origin.x - nextFrame.origin.x) >= 0.5
        || fabs(rail.frame.origin.y - nextFrame.origin.y) >= 0.5
        || fabs(rail.frame.size.width - nextFrame.size.width) >= 0.5
        || fabs(rail.frame.size.height - nextFrame.size.height) >= 0.5) {
        rail.frame = nextFrame;
    }
    if (rail.superview != tabs.view) {
        [tabs.view addSubview:rail];
    }
    [tabs.view bringSubviewToFront:rail];
    NSNumber *selected = objc_getAssociatedObject(tabs, &kApolloDuoRailSelectedKey);
    if (selected) {
        [rail apollo_setSelectedItem:(ApolloDuoRailItem)selected.integerValue];
    } else {
        [rail apollo_setSelectedItem:ApolloDuoRailItemSubreddits];
    }
    [rail apollo_applyTheme];

    CGFloat wantLeft = (CGFloat)ApolloDuoRailChromeLeftForMode(mode);
    CGFloat wantRight = (CGFloat)ApolloDuoRailChromeRightForMode(mode);
    CGFloat wantBottom = 0.0;
    if (mode == ApolloDuoModeClosed && ApolloDuoCoverShouldApplyForTabs(tabs)) {
        wantBottom = (CGFloat)ApolloDuoCoverPillBottom;
    }
    ApolloDuoApplyChromeInsets(tabs, wantLeft, wantBottom, wantRight);
    ApolloDuoRailSetTabBarHidden(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (wasActive && previousMode != mode && previousMode != ApolloDuoModePhone) {
        ApolloDuoRailClearOpenContent();
    }
    objc_setAssociatedObject(tabs, &kApolloDuoRailModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoRailFillOpenContent();
    if (!wasActive || previousMode != mode) {
        ApolloLog(@"[DuoRail] shown %s sidebar (%.0f,%.0f %.0fx%.0f) mode=%d",
                  leading ? "leading" : "trailing",
                  frame.x, frame.y, frame.width, frame.height, mode);
        if (!sApolloDuoRailOpenedDefaultDirectory) {
            sApolloDuoRailOpenedDefaultDirectory = YES;
            ApolloDuoRailOpenDefaultDirectory(tabs);
        }
        ApolloDuoRailReanchorCurrentListSoon();
    }
    ApolloDuoSubsChromeApplyToTabs(tabs);
}
