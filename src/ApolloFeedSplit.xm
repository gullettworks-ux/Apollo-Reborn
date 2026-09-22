// ApolloFeedSplit.xm
// Open Duo browsing surface: My Subreddits | Home feed | Selected post/comments.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloFeedSplitLayout.h"
#import "ApolloThemeRuntime.h"

static char kApolloDuoSplitHostKey;
static char kApolloDuoSplitOriginalSuperviewKey;
static char kApolloDuoSplitOriginalFrameKey;
static char kApolloDuoSplitInsetsClearedKey;
static BOOL sApolloDuoSplitAttaching = NO;
static __weak UITabBarController *sApolloDuoSplitTabs = nil;
static NSUInteger sApolloDuoSplitAttachRetries = 0;
static char kApolloDuoSplitRelayoutKey;
// Profile and Settings are whole tabs, not panes. While one of them is
// showing, the split host steps aside (stock tabs plus the rail take over)
// until the user returns to the feed tab.
static BOOL sApolloDuoSplitSuspended = NO;
@class ApolloDuoSplitHost;
static UINavigationController *ApolloFeedSplitPostsNavigation(UITabBarController *tabs);
static void ApolloFeedSplitOpenHomeFeed(UINavigationController *nav);
static void ApolloFeedSplitFillDetailScrollViews(UIView *view);
static void ApolloFeedSplitWidenDetailSoon(void);
static void ApolloFeedSplitDetach(UITabBarController *tabs);
static BOOL ApolloFeedSplitHandleUtility(ApolloDuoSplitHost *host, NSString *title);
static void ApolloFeedSplitLogDetailFrames(ApolloDuoSplitHost *host);
static void ApolloFeedSplitDumpDetailTree(UIView *view, CGFloat targetWidth, NSInteger depth);
static BOOL ApolloDuoSplitIsOpen(void);

// Apollo's ASTableView recreates/layouts its visible cells after the host's
// pass. Apply the Duo width after Apollo's own layout has finished.
%group ApolloDuoFeedSplitTable
%hook ASTableView
- (void)layoutSubviews {
    %orig;
    if (!ApolloDuoSplitIsOpen()) return;
    UITableView *table = (UITableView *)self;
    CGFloat width = CGRectGetWidth(table.bounds);
    if (width < 1.0) return;
    table.cellLayoutMarginsFollowReadableWidth = NO;
    table.layoutMargins = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) table.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    for (UITableViewCell *cell in table.visibleCells) {
        CGRect cellFrame = cell.frame;
        cellFrame.size.width = width;
        cell.frame = cellFrame;
        cell.preservesSuperviewLayoutMargins = NO;
        cell.layoutMargins = UIEdgeInsetsZero;
        CGRect contentFrame = cell.contentView.frame;
        contentFrame.size.width = width;
        cell.contentView.frame = contentFrame;
    }
}
%end
%end

static void ApolloFeedSplitWidenTableCells(UIView *view, CGFloat tableWidth) {
    if (!view) return;
    CGFloat inheritedWidth = tableWidth;
    if ([view isKindOfClass:[UITableView class]] ||
        [NSStringFromClass(view.class) rangeOfString:@"TableView"].location != NSNotFound) {
        inheritedWidth = CGRectGetWidth(view.bounds);
        if ([view isKindOfClass:[UITableView class]]) {
            UITableView *table = (UITableView *)view;
            // On the Duo, UIKit's readable-width behavior was shrinking
            // 472pt table rows to 389pt and leaving the visible blank strip.
            table.cellLayoutMarginsFollowReadableWidth = NO;
            table.layoutMargins = UIEdgeInsetsZero;
            if (@available(iOS 11.0, *)) {
                table.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
            }
            table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            table.contentInset = UIEdgeInsetsZero;
            table.scrollIndicatorInsets = UIEdgeInsetsZero;
        }
    }
    for (UIView *child in [view.subviews copy]) {
        NSString *className = NSStringFromClass(child.class);
        if (inheritedWidth > 0.0 && [className rangeOfString:@"Cell"].location != NSNotFound) {
            CGRect frame = child.frame;
            if (frame.size.width < inheritedWidth - 1.0) {
                frame.size.width = inheritedWidth;
                child.frame = frame;
            }
            UIView *content = [child respondsToSelector:@selector(contentView)]
                ? [(UITableViewCell *)child contentView] : nil;
            if (content) {
                CGRect contentFrame = content.frame;
                contentFrame.size.width = CGRectGetWidth(child.bounds);
                content.frame = contentFrame;
            }
            if ([child respondsToSelector:@selector(setPreservesSuperviewLayoutMargins:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(child,
                                                        @selector(setPreservesSuperviewLayoutMargins:),
                                                        NO);
            }
            child.layoutMargins = UIEdgeInsetsZero;
        }
        ApolloFeedSplitWidenTableCells(child, inheritedWidth);
    }
}

// Texture caches each row's layout at the width it was first measured. A row
// built before the pane was widened stays narrow, leaving a blank strip on the
// right. Ask every table to re-measure at its current width.
static void ApolloFeedSplitRelayoutTables(UIView *view) {
    if (!view) return;
    if ([NSStringFromClass(view.class) rangeOfString:@"ASTableView"].location != NSNotFound) {
        SEL relayout = NSSelectorFromString(@"relayoutItems");
        if ([view respondsToSelector:relayout]) {
            ((void (*)(id, SEL))objc_msgSend)(view, relayout);
        }
    }
    for (UIView *child in [view.subviews copy]) ApolloFeedSplitRelayoutTables(child);
}

static void ApolloFeedSplitWalkController(UIViewController *vc,
                                          UITabBarController **found) {
    if (!vc || !found || *found) return;
    if ([vc isKindOfClass:[UITabBarController class]]) {
        *found = (UITabBarController *)vc;
        return;
    }
    for (UIViewController *child in vc.childViewControllers) {
        ApolloFeedSplitWalkController(child, found);
    }
    if (vc.presentedViewController) {
        ApolloFeedSplitWalkController(vc.presentedViewController, found);
    }
}

static UITabBarController *ApolloFeedSplitFindVisibleTabs(void) {
    UITabBarController *found = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow || window.windowLevel == UIWindowLevelNormal) {
            ApolloFeedSplitWalkController(window.rootViewController, &found);
            if (found) break;
        }
    }
    return found;
}

@interface ApolloDuoSplitHost : UIView
@property (nonatomic, weak) UITabBarController *tabs;
@property (nonatomic, strong) UIView *sidebar;
@property (nonatomic, strong) UIView *feedColumn;
@property (nonatomic, strong) UIView *detailColumn;
@property (nonatomic, strong) UIView *feedSeparator;
@property (nonatomic, strong) UIView *detailSeparator;
@property (nonatomic, strong) UIView *sidebarHeader;
@property (nonatomic, strong) UIView *feedHeader;
@property (nonatomic, strong) UIView *detailHeader;
@property (nonatomic, strong) UILabel *detailHeaderTitle;
@property (nonatomic, strong) UILabel *feedHeaderTitle;
@property (nonatomic, strong) UINavigationController *detailNavigation;
@property (nonatomic, weak) UINavigationController *feedNavigation;
- (instancetype)initWithTabs:(UITabBarController *)tabs feed:(UINavigationController *)feed;
- (void)layoutColumns;
- (void)showDetailViewController:(UIViewController *)controller;
- (void)clearDetail;
- (void)popFeedNavigation;
@end

static BOOL ApolloDuoSplitIsOpen(void) {
    // Window mode is authoritative. The rail's active flag is installed by a
    // separate layout pass and can still be NO while the open Duo canvas is
    // already ready for the three-pane host.
    //
    // Read the live window size, not the rail's stored mode: while this host
    // is attached the rail's sync returns early and never refreshes that
    // stored value, so a rotate out of Open would leave the host squashed.
    UIWindow *window = sApolloDuoSplitTabs.view.window;
    if (window) {
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) return NO;
        CGSize size = window.bounds.size;
        return ApolloDuoModeFromBounds(0, size.width, size.height) == ApolloDuoModeOpen;
    }
    return ApolloDuoCurrentMode() == ApolloDuoModeOpen;
}

static UIColor *ApolloDuoSplitPageColor(void) {
    return ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
}

static UIColor *ApolloDuoSplitSeparatorColor(void) {
    return ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
}

@interface ApolloDuoSplitSidebarButton : UIButton
@property (nonatomic, copy) NSString *route;
@property (nonatomic, copy) NSString *feedTitle;
// Selectable items (Home/Popular/All/Subreddits) hold the highlight; action
// items (Profile/Settings) do not.
@property (nonatomic, assign) BOOL selectable;
@property (nonatomic, assign) BOOL pinnedBottom;
@end
@implementation ApolloDuoSplitSidebarButton
// Icon-over-label rail item, as in the reference layout.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGSize icon = self.imageView.image.size;
    self.imageView.frame = CGRectMake(floor((width - icon.width) * 0.5), 10.0,
                                      icon.width, icon.height);
    self.titleLabel.frame = CGRectMake(4.0, 38.0, MAX(0.0, width - 8.0), 28.0);
}
@end

static void ApolloDuoSplitStyleSidebarButton(UIButton *button, BOOL selected);

@interface ApolloDuoSplitSidebarController : NSObject
@property (nonatomic, weak) ApolloDuoSplitHost *host;
@end

@implementation ApolloDuoSplitSidebarController
- (void)select:(ApolloDuoSplitSidebarButton *)button {
    if (!button.selectable) return;
    for (UIView *view in button.superview.subviews) {
        if (![view isKindOfClass:[ApolloDuoSplitSidebarButton class]]) continue;
        ApolloDuoSplitSidebarButton *other = (ApolloDuoSplitSidebarButton *)view;
        if (!other.selectable) continue;
        ApolloDuoSplitStyleSidebarButton(other, other == button);
    }
    UILabel *headerTitle = [self.host.feedHeader viewWithTag:9001];
    if (button.feedTitle.length) headerTitle.text = button.feedTitle;
}

- (void)tap:(ApolloDuoSplitSidebarButton *)sender {
    if (!sender.route.length) return;
    [self select:sender];
    if ([sender.route isEqualToString:@"apollo://subreddits"]) {
        // The Posts-tab root is Apollo's own subreddit list; show it in the
        // feed pane.
        UINavigationController *nav = self.host.feedNavigation;
        if (nav.viewControllers.count > 1) [nav popToRootViewControllerAnimated:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.host layoutColumns]; });
        return;
    }
    if ([sender.route isEqualToString:@"apollo://profile"]) {
        UITabBarController *tabs = self.host.tabs;
        // Selecting the Profile tab underneath would be hidden by this host,
        // so hand the canvas back to the stock tabs first. Nothing below may
        // touch self: detaching the host releases this controller.
        sApolloDuoSplitSuspended = YES;
        ApolloFeedSplitDetach(tabs);
        if ([tabs respondsToSelector:@selector(goToProfileTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToProfileTab));
        }
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoRailSync(); });
        return;
    }
    if ([sender.route isEqualToString:@"apollo://home"]) {
        UITabBarController *tabs = self.host.tabs;
        if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloFeedSplitOpenHomeFeed(ApolloFeedSplitPostsNavigation(tabs));
        });
        return;
    }
    if ([sender.route isEqualToString:@"apollo://saved"] ||
        [sender.route isEqualToString:@"apollo://history"] ||
        [sender.route isEqualToString:@"apollo://settings"]) {
        NSString *title = [sender.route hasSuffix:@"saved"] ? @"SAVED" :
                           ([sender.route hasSuffix:@"history"] ? @"HISTORY" : @"SETTINGS");
        ApolloFeedSplitHandleUtility(self.host, title);
        return;
    }
    NSURL *url = [NSURL URLWithString:sender.route];
    if (url) {
        __block BOOL routed = NO;
        [UIView performWithoutAnimation:^{ routed = ApolloRouteURLThroughApp(url); }];
        if (routed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.host layoutColumns];
            });
        }
    }
}
@end

static BOOL ApolloFeedSplitHandleUtility(ApolloDuoSplitHost *host, NSString *title) {
    if (!host || !host.tabs) return NO;
    UITabBarController *tabs = host.tabs;
    if ([title isEqualToString:@"SETTINGS"]) {
        sApolloDuoSplitSuspended = YES;
        ApolloFeedSplitDetach(tabs);
        BOOL opened = NO;
        if ([tabs respondsToSelector:@selector(goToSettingsTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToSettingsTab));
            opened = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoRailSync(); });
        return opened;
    }

    UINavigationController *nav = host.feedNavigation;
    if (!nav) return NO;

    // Do not construct Apollo's Swift Saved controller by class name. Its
    // initializer is private/version-specific and can trap during dispatch on
    // the simulator. Prefer Apollo's own tab/URL routing, which also preserves
    // its normal data loading and authentication behavior.
    SEL directSelector = [title isEqualToString:@"SAVED"] ? @selector(goToSavedTab) :
                         ([title isEqualToString:@"HISTORY"] ? @selector(goToHistoryTab) : NULL);
    if (directSelector && [tabs respondsToSelector:directSelector]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabs, directSelector);
            ApolloLog(@"[FeedSplit] opened %@ through Apollo tab routing", title);
            return YES;
        } @catch (NSException *exception) {
            ApolloLog(@"[FeedSplit] %@ tab routing failed: %@", title, exception);
        }
    }

    NSString *route = [title isEqualToString:@"SAVED"] ? @"apollo://saved" : @"apollo://history";
    NSURL *url = [NSURL URLWithString:route];
    __block BOOL routed = NO;
    @try {
        [UIView performWithoutAnimation:^{ routed = ApolloRouteURLThroughApp(url); }];
    } @catch (NSException *exception) {
        ApolloLog(@"[FeedSplit] %@ URL routing failed: %@", title, exception);
    }
    if (!routed) {
        ApolloLog(@"[FeedSplit] Apollo has no safe %@ route on this build", title);
        return NO;
    }

    UILabel *headerTitle = [host.feedHeader viewWithTag:9001];
    headerTitle.text = title;
    dispatch_async(dispatch_get_main_queue(), ^{
        [host layoutColumns];
    });
    ApolloLog(@"[FeedSplit] opened %@ through Apollo URL routing", title);
    return YES;
}

static void ApolloDuoSplitStyleSidebarButton(UIButton *button, BOOL selected) {
    UIColor *accent = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    UIColor *muted = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    [button setTitleColor:selected ? accent : muted forState:UIControlStateNormal];
    button.tintColor = selected ? accent : muted;
    button.backgroundColor = selected ? [accent colorWithAlphaComponent:0.14] : UIColor.clearColor;
}

static ApolloDuoSplitSidebarButton *ApolloDuoSplitMakeSidebarButton(ApolloDuoSplitSidebarController *target,
                                                                    NSString *title,
                                                                    NSString *symbol,
                                                                    NSString *route,
                                                                    NSString *feedTitle,
                                                                    BOOL selectable,
                                                                    BOOL selected) {
    ApolloDuoSplitSidebarButton *button = [ApolloDuoSplitSidebarButton buttonWithType:UIButtonTypeSystem];
    button.route = route;
    button.feedTitle = feedTitle;
    button.selectable = selectable;
    button.accessibilityLabel = title;
    button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.layer.cornerRadius = 12.0;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    ApolloDuoSplitStyleSidebarButton(button, selected);
    [button addTarget:target action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UIView *ApolloDuoSplitHeader(NSString *title, UIColor *background) {
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.backgroundColor = background ?: UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    label.textColor = UIColor.labelColor;
    label.tag = 9001;
    [header addSubview:label];
    UIView *rule = [[UIView alloc] initWithFrame:CGRectZero];
    rule.backgroundColor = ApolloDuoSplitSeparatorColor();
    rule.tag = 9002;
    [header addSubview:rule];
    return header;
}

static UIButton *ApolloDuoSplitHeaderButton(NSString *symbol, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UIView *ApolloDuoSplitBuildSidebar(ApolloDuoSplitHost *host) {
    UIView *sidebar = [[UIView alloc] initWithFrame:CGRectZero];
    sidebar.backgroundColor = ApolloDuoSplitPageColor();
    sidebar.accessibilityLabel = @"Navigation";
    ApolloDuoSplitSidebarController *target = [ApolloDuoSplitSidebarController new];
    target.host = host;
    objc_setAssociatedObject(sidebar, "apollo.sidebar.target", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Narrow icon rail from the reference layout. Frames are set in
    // -layoutColumns (top stack, Settings pinned to the bottom).
    NSArray<NSDictionary *> *items = @[
        @{ @"title": @"Home",          @"symbol": @"house.fill", @"route": @"apollo://home",
           @"feed": @"Home", @"selectable": @YES, @"selected": @YES },
        @{ @"title": @"Popular",       @"symbol": @"safari",     @"route": @"apollo://reddit.com/r/popular",
           @"feed": @"Popular", @"selectable": @YES },
        @{ @"title": @"All",           @"symbol": @"globe",      @"route": @"apollo://reddit.com/r/all",
           @"feed": @"All", @"selectable": @YES },
        @{ @"title": @"My Subreddits", @"symbol": @"bookmark",   @"route": @"apollo://subreddits",
           @"feed": @"My Subreddits", @"selectable": @YES },
        @{ @"title": @"Profile",       @"symbol": @"person",     @"route": @"apollo://profile" },
        @{ @"title": @"Settings",      @"symbol": @"gearshape",  @"route": @"apollo://settings",
           @"pinned": @YES },
    ];
    for (NSDictionary *item in items) {
        ApolloDuoSplitSidebarButton *button =
            ApolloDuoSplitMakeSidebarButton(target, item[@"title"], item[@"symbol"], item[@"route"],
                                            item[@"feed"], [item[@"selectable"] boolValue],
                                            [item[@"selected"] boolValue]);
        button.pinnedBottom = [item[@"pinned"] boolValue];
        [sidebar addSubview:button];
    }
    return sidebar;
}

@implementation ApolloDuoSplitHost
- (instancetype)initWithTabs:(UITabBarController *)tabs feed:(UINavigationController *)feed {
    self = [super initWithFrame:CGRectZero];
    if (!self) return self;
    self.tabs = tabs;
    self.feedNavigation = feed;
    self.backgroundColor = ApolloDuoSplitPageColor();
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.sidebar = ApolloDuoSplitBuildSidebar(self);
    self.feedColumn = [[UIView alloc] initWithFrame:CGRectZero];
    self.detailColumn = [[UIView alloc] initWithFrame:CGRectZero];
    self.feedColumn.backgroundColor = ApolloDuoSplitPageColor();
    self.detailColumn.backgroundColor = ApolloDuoSplitPageColor();
    self.feedSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    self.detailSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    self.feedSeparator.backgroundColor = ApolloDuoSplitSeparatorColor();
    self.detailSeparator.backgroundColor = ApolloDuoSplitSeparatorColor();
    [self addSubview:self.sidebar];
    [self addSubview:self.feedColumn];
    [self addSubview:self.detailColumn];
    [self addSubview:self.feedSeparator];
    [self addSubview:self.detailSeparator];

    // Dedicated Duo headers match the reference sketch and keep Apollo's
    // phone toolbar from consuming the center column.
    self.sidebarHeader = ApolloDuoSplitHeader(@"MY SUBREDDITS", self.sidebar.backgroundColor);
    self.feedHeader = ApolloDuoSplitHeader(@"Home", self.feedColumn.backgroundColor);
    self.detailHeader = ApolloDuoSplitHeader(@"Comments", self.detailColumn.backgroundColor);
    self.detailHeaderTitle = [self.detailHeader viewWithTag:9001];
    self.feedHeaderTitle = [self.feedHeader viewWithTag:9001];
    [self.sidebar addSubview:self.sidebarHeader];
    [self.feedColumn addSubview:self.feedHeader];
    [self.detailColumn addSubview:self.detailHeader];

    UIButton *plus = ApolloDuoSplitHeaderButton(@"plus", self, @selector(addSubreddit));
    plus.frame = CGRectMake(0, 0, 40, 40);
    plus.accessibilityLabel = @"Add subreddit";
    [self.sidebarHeader addSubview:plus];
    // Apollo's real nav bar (with its own back chevron) is hidden below to make
    // room for this header, so once feedNavigation is pushed past its root
    // (e.g. into a subreddit) there is otherwise no way back -- see
    // layoutColumns, which shows/hides and positions this based on stack depth.
    UIButton *feedBack = ApolloDuoSplitHeaderButton(@"chevron.left", self, @selector(popFeedNavigation));
    feedBack.tag = 9100;
    feedBack.frame = CGRectMake(0, 0, 40, 40);
    feedBack.hidden = YES;
    feedBack.accessibilityLabel = @"Back";
    [self.feedHeader addSubview:feedBack];
    UIButton *feedSearch = ApolloDuoSplitHeaderButton(@"magnifyingglass", self, @selector(searchFeed));
    feedSearch.tag = 9101;
    feedSearch.frame = CGRectMake(0, 0, 40, 40);
    [self.feedHeader addSubview:feedSearch];
    UIButton *feedMore = ApolloDuoSplitHeaderButton(@"ellipsis", self, @selector(noopHeaderAction));
    feedMore.tag = 9102;
    feedMore.frame = CGRectMake(0, 0, 40, 40);
    [self.feedHeader addSubview:feedMore];
    UIButton *detailBack = ApolloDuoSplitHeaderButton(@"chevron.left", self, @selector(clearDetail));
    detailBack.tag = 9201;
    detailBack.frame = CGRectMake(0, 0, 40, 40);
    [self.detailHeader addSubview:detailBack];
    UIButton *detailMore = ApolloDuoSplitHeaderButton(@"ellipsis", self, @selector(noopHeaderAction));
    detailMore.tag = 9202;
    detailMore.frame = CGRectMake(0, 0, 40, 40);
    [self.detailHeader addSubview:detailMore];

    UIViewController *placeholder = [UIViewController new];
    // The Apollo navigation subclass carries phone-width/rail assumptions and
    // can re-constrain a comments view to roughly 320pt even inside the Duo
    // detail column. A plain UIKit navigation controller keeps this pane's
    // width owned entirely by the three-pane host.
    self.detailNavigation = [[UINavigationController alloc] initWithRootViewController:placeholder];
    [self.detailNavigation setNavigationBarHidden:YES animated:NO];
    // Keep the detail navigation inside the right column. When it was a
    // sibling of detailColumn, Apollo's comments controller calculated its
    // content width in host coordinates and repeatedly left a blank strip.
    [self.detailColumn addSubview:self.detailNavigation.view];
    [placeholder.view removeFromSuperview];
    [self layoutColumns];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutColumns];
}

- (void)layoutColumns {
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 1.0 || height < 1.0) return;
    // Book layout: the hinge is the middle of the canvas. The left screen
    // holds the icon rail plus the feed; the right screen holds the selected
    // post and comments. Nothing spans the hinge.
    ApolloDuoSplitColumns cols = ApolloDuoSplitColumnsMake(width,
                                                           (double)ApolloDuoSplitRailWidth,
                                                           (double)ApolloDuoSplitHingeGap);
    CGFloat sidebarWidth = (CGFloat)cols.railWidth;
    CGFloat feedWidth = (CGFloat)cols.feedWidth;
    CGFloat detailWidth = (CGFloat)cols.detailWidth;
    self.sidebar.frame = CGRectMake((CGFloat)cols.railX, 0.0, sidebarWidth, height);
    self.feedColumn.frame = CGRectMake((CGFloat)cols.feedX, 0.0, feedWidth, height);
    self.feedSeparator.frame = CGRectMake((CGFloat)cols.feedX - 1.0, 0.0, 1.0, height);
    self.detailSeparator.frame = CGRectMake((CGFloat)cols.hingeX - 0.5, 0.0, 1.0, height);
    self.detailColumn.frame = CGRectMake((CGFloat)cols.detailX, 0.0, detailWidth, height);
    self.sidebarHeader.hidden = YES;
    {
        const CGFloat itemHeight = 72.0;
        const CGFloat itemGap = 6.0;
        CGFloat itemWidth = MAX(0.0, sidebarWidth - 16.0);
        CGFloat stackY = MAX(self.safeAreaInsets.top, 26.0) + 12.0;
        CGFloat bottomInset = MAX(self.safeAreaInsets.bottom, 12.0);
        for (UIView *view in self.sidebar.subviews) {
            if (![view isKindOfClass:[ApolloDuoSplitSidebarButton class]]) continue;
            ApolloDuoSplitSidebarButton *item = (ApolloDuoSplitSidebarButton *)view;
            if (item.pinnedBottom) {
                item.frame = CGRectMake(8.0, height - bottomInset - itemHeight, itemWidth, itemHeight);
            } else {
                item.frame = CGRectMake(8.0, stackY, itemWidth, itemHeight);
                stackY += itemHeight + itemGap;
            }
        }
    }
    // The Duo status bar (clock, Wi-Fi) overlays the top of the right screen;
    // keep every header and the rail below it so nothing collides, and so the
    // headers line up across the hinge like the reference layout.
    CGFloat topInset = MAX(self.safeAreaInsets.top, 26.0);
    CGFloat headerHeight = 52.0 + topInset;
    self.sidebarHeader.frame = CGRectMake(0.0, 0.0, sidebarWidth, headerHeight);
    self.feedHeader.frame = CGRectMake(0.0, 0.0, feedWidth, headerHeight);
    self.detailHeader.frame = CGRectMake(0.0, 0.0, detailWidth, headerHeight);
    for (UIView *header in @[self.sidebarHeader, self.feedHeader, self.detailHeader]) {
        UILabel *label = [header viewWithTag:9001];
        UIView *rule = [header viewWithTag:9002];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.68;
        label.frame = CGRectMake(18.0, topInset + 8.0, MAX(108.0, CGRectGetWidth(header.bounds) - 58.0), 34.0);
        rule.frame = CGRectMake(0.0, headerHeight - 1.0, CGRectGetWidth(header.bounds), 1.0);
    }
    UIButton *plus = self.sidebarHeader.subviews.lastObject;
    plus.frame = CGRectMake(sidebarWidth - 48.0, topInset + 6.0, 40.0, 40.0);
    NSArray *feedButtons = @[[self.feedHeader viewWithTag:9101], [self.feedHeader viewWithTag:9102]];
    feedButtons = (feedButtons[0] && feedButtons[1]) ? feedButtons : @[];
    if (feedButtons.count == 2) {
        [feedButtons[0] setFrame:CGRectMake(feedWidth - 92.0, topInset + 6.0, 40.0, 40.0)];
        [feedButtons[1] setFrame:CGRectMake(feedWidth - 48.0, topInset + 6.0, 40.0, 40.0)];
    }
    // Only the root of feedNavigation (Home/My Subreddits list) hides behind
    // this custom header with no way back; anything pushed on top of it needs
    // a real back control since Apollo's own nav bar stays hidden throughout.
    BOOL feedHasBack = self.feedNavigation.viewControllers.count > 1;
    UIButton *feedBack = [self.feedHeader viewWithTag:9100];
    feedBack.hidden = !feedHasBack;
    if (feedHasBack) {
        feedBack.frame = CGRectMake(10.0, topInset + 6.0, 40.0, 40.0);
    }
    if (self.feedHeaderTitle) {
        self.feedHeaderTitle.frame = feedHasBack
            ? CGRectMake(58.0, topInset + 8.0, MAX(108.0, feedWidth - 150.0), 34.0)
            : CGRectMake(18.0, topInset + 8.0, MAX(108.0, feedWidth - 58.0), 34.0);
    }
    NSArray *detailButtons = @[[self.detailHeader viewWithTag:9201], [self.detailHeader viewWithTag:9202]];
    detailButtons = (detailButtons[0] && detailButtons[1]) ? detailButtons : @[];
    if (detailButtons.count == 2) {
        [detailButtons[0] setFrame:CGRectMake(10.0, topInset + 6.0, 40.0, 40.0)];
        [detailButtons[1] setFrame:CGRectMake(detailWidth - 48.0, topInset + 6.0, 40.0, 40.0)];
        self.detailHeaderTitle.frame = CGRectMake(58.0, topInset + 8.0, MAX(120.0, detailWidth - 116.0), 34.0);
    }
    // detailNavigation is hosted by detailColumn, so use column-local
    // coordinates and the exact available width.
    CGRect detailFrame = CGRectMake(0.0,
                                    headerHeight,
                                    CGRectGetWidth(self.detailColumn.bounds),
                                    MAX(0.0, CGRectGetHeight(self.detailColumn.bounds) - headerHeight));
    if (!CGRectEqualToRect(self.detailNavigation.view.frame, detailFrame)) {
        self.detailNavigation.view.frame = detailFrame;
    }
    self.detailNavigation.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.detailNavigation.view.clipsToBounds = YES;
    UIViewController *detailVisible = self.detailNavigation.visibleViewController;
    if (detailVisible.isViewLoaded && detailVisible.view.superview) {
        detailVisible.view.translatesAutoresizingMaskIntoConstraints = YES;
        detailVisible.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        detailVisible.view.insetsLayoutMarginsFromSafeArea = NO;
        detailVisible.additionalSafeAreaInsets = UIEdgeInsetsZero;
        detailVisible.edgesForExtendedLayout = UIRectEdgeAll;
        detailVisible.extendedLayoutIncludesOpaqueBars = YES;
        [self.detailNavigation.view layoutIfNeeded];
        CGRect detailBounds = self.detailNavigation.view.bounds;
        BOOL detailFrameChanged = !CGRectEqualToRect(detailVisible.view.frame, detailBounds);
        if (detailFrameChanged) detailVisible.view.frame = detailBounds;
        // Apollo's comments controller can install a second content wrapper
        // after the navigation controller lays out. Widen the complete
        // hierarchy, including the root when it is itself a scroll view.
        detailVisible.view.bounds = detailBounds;
        ApolloFeedSplitFillDetailScrollViews(detailVisible.view);
        ApolloFeedSplitWidenTableCells(detailVisible.view, 0.0);
        NSString *relayoutKey = [NSString stringWithFormat:@"%p-%.0f", detailVisible,
                                 CGRectGetWidth(detailBounds)];
        if (![relayoutKey isEqualToString:objc_getAssociatedObject(self, &kApolloDuoSplitRelayoutKey)]) {
            objc_setAssociatedObject(self, &kApolloDuoSplitRelayoutKey, relayoutKey,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloFeedSplitRelayoutTables(detailVisible.view);
            __weak UIViewController *weakDetail = detailVisible;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *detail = weakDetail;
                if (detail.isViewLoaded) ApolloFeedSplitRelayoutTables(detail.view);
            });
        }
        ApolloFeedSplitWidenDetailSoon();
        if (detailFrameChanged) [detailVisible.view setNeedsLayout];
    }
    if (self.feedNavigation.view.superview == self.feedColumn) {
        // The reference sketch has one clean HOME header. Apollo's original
        // navigation bar (trophy/search capsule) is phone chrome and must not
        // remain stacked underneath it.
        [self.feedNavigation setNavigationBarHidden:YES animated:NO];
        CGRect feedFrame = CGRectMake(0.0, headerHeight, feedWidth,
                                      MAX(0.0, height - headerHeight));
        BOOL feedFrameChanged = !CGRectEqualToRect(self.feedNavigation.view.frame, feedFrame);
        if (feedFrameChanged) self.feedNavigation.view.frame = feedFrame;
        self.feedNavigation.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.feedColumn bringSubviewToFront:self.feedHeader];
        UIViewController *visible = self.feedNavigation.visibleViewController;
        if (visible.isViewLoaded && visible.view.superview) {
            CGRect visibleFrame = self.feedNavigation.view.bounds;
            BOOL visibleFrameChanged = !CGRectEqualToRect(visible.view.frame, visibleFrame);
            if (visibleFrameChanged) visible.view.frame = visibleFrame;
            visible.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            if (feedFrameChanged || visibleFrameChanged) [visible.view setNeedsLayout];
        }
    }
    ApolloFeedSplitLogDetailFrames(self);
}

- (void)addSubreddit { }
- (void)searchFeed { }
- (void)noopHeaderAction { }

- (void)showDetailViewController:(UIViewController *)controller {
    if (!controller || !ApolloDuoSplitIsOpen()) return;
    [self.detailNavigation setViewControllers:@[controller] animated:NO];
    controller.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                       target:self action:@selector(clearDetail)];
    [self layoutColumns];
    ApolloLog(@"[FeedSplit] selected post hosted in right pane: %@", NSStringFromClass(controller.class));
}

- (void)clearDetail {
    UIViewController *placeholder = [UIViewController new];
    placeholder.view.backgroundColor = ApolloDuoSplitPageColor();
    [self.detailNavigation setViewControllers:@[placeholder] animated:NO];
}

- (void)popFeedNavigation {
    if (self.feedNavigation.viewControllers.count > 1) {
        [self.feedNavigation popViewControllerAnimated:NO];
    }
    [self layoutColumns];
}
@end

static UINavigationController *ApolloFeedSplitPostsNavigation(UITabBarController *tabs) {
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = [child isKindOfClass:[UINavigationController class]]
            ? (UINavigationController *)child : child.navigationController;
        if (!nav) continue;
        for (UIViewController *vc in nav.viewControllers) {
            if ((listClass && [vc isKindOfClass:listClass]) ||
                (postsClass && [vc isKindOfClass:postsClass])) return nav;
        }
    }
    UIViewController *selected = tabs.selectedViewController;
    return [selected isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)selected : selected.navigationController;
}

static void ApolloFeedSplitOpenHomeFeed(UINavigationController *nav) {
    if (!nav) return;
    [nav popToRootViewControllerAnimated:NO];
    UIViewController *root = nav.viewControllers.firstObject;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!root || (listClass && ![root isKindOfClass:listClass])) return;
    if (!root.isViewLoaded) [root loadViewIfNeeded];
    UITableView *tableView = nil;
    if ([root respondsToSelector:@selector(tableView)]) {
        @try {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(root, @selector(tableView));
        } @catch (__unused NSException *exception) {
            tableView = nil;
        }
    }
    if ([root respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        NSIndexPath *home = [NSIndexPath indexPathForRow:0 inSection:0];
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(root,
                @selector(tableView:didSelectRowAtIndexPath:), tableView, home);
        } @catch (__unused NSException *exception) {
        }
    }
}

static void ApolloFeedSplitDetach(UITabBarController *tabs) {
    ApolloDuoSplitHost *host = objc_getAssociatedObject(tabs, &kApolloDuoSplitHostKey);
    if (!host) return;
    UINavigationController *feed = host.feedNavigation;
    UIView *original = objc_getAssociatedObject(feed, &kApolloDuoSplitOriginalSuperviewKey);
    NSValue *savedFrame = objc_getAssociatedObject(feed, &kApolloDuoSplitOriginalFrameKey);
    if (feed.view.superview == host.feedColumn) {
        [feed.view removeFromSuperview];
        if (original) {
            [original addSubview:feed.view];
            feed.view.frame = savedFrame ? savedFrame.CGRectValue : original.bounds;
        }
    }
    [host removeFromSuperview];
    objc_setAssociatedObject(tabs, &kApolloDuoSplitHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalSuperviewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(feed, &kApolloDuoSplitInsetsClearedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedSplitHideLegacyRail(UITabBarController *tabs) {
    if (!tabs.isViewLoaded) return;
    for (UIView *subview in tabs.view.subviews) {
        const char *name = class_getName(subview.class);
        if (name && (strstr(name, "ApolloDuoRail") != NULL
                     || strstr(name, "DuoRailView") != NULL)) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
        }
    }
}

static void ApolloFeedSplitClearLegacyInsetsInView(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        UIEdgeInsets inset = scroll.contentInset;
        inset.left = 0.0;
        scroll.contentInset = inset;
        UIEdgeInsets indicator = scroll.scrollIndicatorInsets;
        indicator.left = 0.0;
        scroll.scrollIndicatorInsets = indicator;
    }
    for (UIView *child in view.subviews) {
        ApolloFeedSplitClearLegacyInsetsInView(child);
    }
}

static void ApolloFeedSplitFillDetailScrollViews(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UIScrollView class]] && view.superview) {
        UIScrollView *scroll = (UIScrollView *)view;
        view.translatesAutoresizingMaskIntoConstraints = YES;
        view.frame = view.superview.bounds;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIEdgeInsets inset = scroll.contentInset;
        inset.left = 0.0;
        inset.right = 0.0;
        scroll.contentInset = inset;
        UIEdgeInsets indicator = scroll.scrollIndicatorInsets;
        indicator.left = 0.0;
        indicator.right = 0.0;
        scroll.scrollIndicatorInsets = indicator;
    }
    for (UIView *child in [view.subviews copy]) {
        if ([child isKindOfClass:[UIScrollView class]] && child.superview) {
            CGRect bounds = child.superview.bounds;
            if (!CGRectEqualToRect(child.frame, bounds)) {
                child.translatesAutoresizingMaskIntoConstraints = YES;
                child.frame = bounds;
                child.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }
            UIScrollView *scroll = (UIScrollView *)child;
            UIEdgeInsets inset = scroll.contentInset;
            inset.left = 0.0;
            inset.right = 0.0;
            scroll.contentInset = inset;
            UIEdgeInsets indicator = scroll.scrollIndicatorInsets;
            indicator.left = 0.0;
            indicator.right = 0.0;
            scroll.scrollIndicatorInsets = indicator;
        }
        ApolloFeedSplitFillDetailScrollViews(child);
    }
}

static BOOL sApolloDuoSplitDetailWidenScheduled = NO;
static NSString *sApolloDuoSplitLastDetailFrameLog = nil;
static void ApolloFeedSplitDumpDetailTree(UIView *view, CGFloat targetWidth, NSInteger depth) {
    if (!view || depth > 5) return;
    for (UIView *child in view.subviews) {
        CGFloat childWidth = CGRectGetWidth(child.bounds);
        if (childWidth < targetWidth - 20.0 ||
            [child isKindOfClass:[UIScrollView class]] ||
            [child isKindOfClass:[UIStackView class]]) {
            ApolloLog(@"[FeedSplit] DETAIL CHILD depth=%ld class=%@ frame=%@ bounds=%@",
                      (long)depth, NSStringFromClass(child.class),
                      NSStringFromCGRect(child.frame), NSStringFromCGRect(child.bounds));
        }
        ApolloFeedSplitDumpDetailTree(child, targetWidth, depth + 1);
    }
}

static void ApolloFeedSplitLogDetailFrames(ApolloDuoSplitHost *host) {
    if (!host || !host.detailNavigation) return;
    UIViewController *visible = host.detailNavigation.visibleViewController;
    UIView *view = visible.isViewLoaded ? visible.view : nil;
    UIScrollView *scroll = nil;
    for (UIView *candidate in view.subviews) {
        if ([candidate isKindOfClass:[UIScrollView class]]) { scroll = (UIScrollView *)candidate; break; }
    }
    NSString *signature = [NSString stringWithFormat:@"host=%@ column=%@ nav=%@ visible=%@ scroll=%@",
                           NSStringFromCGRect(host.bounds),
                           NSStringFromCGRect(host.detailColumn.frame),
                           NSStringFromCGRect(host.detailNavigation.view.frame),
                           view ? NSStringFromCGRect(view.frame) : @"<not-loaded>",
                           scroll ? NSStringFromCGRect(scroll.frame) : @"<none>"];
    if (![signature isEqualToString:sApolloDuoSplitLastDetailFrameLog]) {
        sApolloDuoSplitLastDetailFrameLog = [signature copy];
        ApolloLog(@"[FeedSplit] DETAIL FRAMES %@", signature);
        if (view) ApolloFeedSplitDumpDetailTree(view, CGRectGetWidth(host.detailNavigation.view.bounds), 0);
    }
}

static void ApolloFeedSplitWidenDetailSoon(void) {
    if (sApolloDuoSplitDetailWidenScheduled) return;
    sApolloDuoSplitDetailWidenScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloDuoSplitDetailWidenScheduled = NO;
        ApolloDuoSplitHost *host = objc_getAssociatedObject(sApolloDuoSplitTabs, &kApolloDuoSplitHostKey);
        if (!host || !host.detailNavigation.visibleViewController.isViewLoaded) return;
        UIViewController *detail = host.detailNavigation.visibleViewController;
        [host.detailNavigation.view layoutIfNeeded];
        detail.view.translatesAutoresizingMaskIntoConstraints = YES;
        detail.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        detail.additionalSafeAreaInsets = UIEdgeInsetsZero;
        detail.edgesForExtendedLayout = UIRectEdgeAll;
        detail.view.frame = host.detailNavigation.view.bounds;
        detail.view.bounds = host.detailNavigation.view.bounds;
        ApolloFeedSplitFillDetailScrollViews(detail.view);
        ApolloFeedSplitWidenTableCells(detail.view, 0.0);
        ApolloFeedSplitDumpDetailTree(detail.view, CGRectGetWidth(host.detailNavigation.view.bounds), 0);
    });
}

static void ApolloFeedSplitClearLegacyInsets(UINavigationController *feed) {
    if (!feed) return;
    feed.additionalSafeAreaInsets = UIEdgeInsetsZero;
    for (UIViewController *controller in feed.viewControllers) {
        controller.additionalSafeAreaInsets = UIEdgeInsetsZero;
        ApolloFeedSplitClearLegacyInsetsInView(controller.view);
    }
    ApolloFeedSplitClearLegacyInsetsInView(feed.view);
}

static void ApolloFeedSplitEnsure(UITabBarController *tabs) {
    if (!tabs || !tabs.isViewLoaded) {
        ApolloLog(@"[FeedSplit] ensure skipped: tabs=%@ loaded=%d", tabs, tabs.isViewLoaded);
        return;
    }
    if (sApolloDuoSplitSuspended) {
        // Back on the feed tab: take the canvas again. (The posts navigation
        // lookup falls back to the selected tab, so only trust a real match.)
        UINavigationController *postsNav = ApolloFeedSplitPostsNavigation(tabs);
        if (postsNav && tabs.selectedViewController == postsNav) sApolloDuoSplitSuspended = NO;
    }
    if (!ApolloDuoSplitIsOpen() || sApolloDuoSplitSuspended) {
        ApolloFeedSplitDetach(tabs);
        return;
    }
    if (sApolloDuoSplitAttaching) return;
    sApolloDuoSplitAttaching = YES;
    UINavigationController *feed = ApolloFeedSplitPostsNavigation(tabs);
    if (!feed) {
        ApolloLog(@"[FeedSplit] posts navigation not ready; retry=%lu", (unsigned long)sApolloDuoSplitAttachRetries);
        if (sApolloDuoSplitAttachRetries++ < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ApolloFeedSplitReapplyVisible();
            });
        } else {
            sApolloDuoSplitAttachRetries = 0;
        }
        sApolloDuoSplitAttaching = NO;
        return;
    }
    ApolloLog(@"[FeedSplit] attaching to tabs=%@ feed=%@ bounds=%@", NSStringFromClass(tabs.class), NSStringFromClass(feed.class), NSStringFromCGRect(tabs.view.bounds));
    sApolloDuoSplitAttachRetries = 0;
    [feed loadViewIfNeeded];
    ApolloDuoSplitHost *host = objc_getAssociatedObject(tabs, &kApolloDuoSplitHostKey);
    BOOL createdHost = NO;
    if (!host || host.feedNavigation != feed) {
        if (host) ApolloFeedSplitDetach(tabs);
        // Restore the legacy rail's frame/inset changes only when creating
        // the host. Repeating this during layout causes visible flicker.
        ApolloDuoRailClearOpenContent();
        host = [[ApolloDuoSplitHost alloc] initWithTabs:tabs feed:feed];
        createdHost = YES;
        objc_setAssociatedObject(tabs, &kApolloDuoSplitHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalSuperviewKey, feed.view.superview, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalFrameKey,
                                 [NSValue valueWithCGRect:feed.view.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [feed.view removeFromSuperview];
        [host.feedColumn addSubview:feed.view];
        [tabs.view addSubview:host];
    }
    host.frame = tabs.view.bounds;
    [host layoutColumns];
    ApolloFeedSplitHideLegacyRail(tabs);
    if (![objc_getAssociatedObject(feed, &kApolloDuoSplitInsetsClearedKey) boolValue]) {
        ApolloFeedSplitClearLegacyInsets(feed);
        objc_setAssociatedObject(feed, &kApolloDuoSplitInsetsClearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [tabs.view bringSubviewToFront:host];
    sApolloDuoSplitTabs = tabs;
    if (createdHost) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host.superview == tabs.view && ApolloDuoSplitIsOpen()) {
                [tabs.view bringSubviewToFront:host];
                [host layoutColumns];
                ApolloFeedSplitHideLegacyRail(tabs);
            }
        });
    }
    sApolloDuoSplitAttaching = NO;
}

BOOL ApolloFeedSplitEnabled(void) {
    return ApolloDuoSplitIsOpen() && objc_getAssociatedObject(sApolloDuoSplitTabs, &kApolloDuoSplitHostKey) != nil;
}
BOOL ApolloFeedSplitForceTiledActive(void) { return ApolloFeedSplitEnabled(); }
void ApolloFeedSplitForceTiledForSeconds(NSTimeInterval seconds) { (void)seconds; }
void ApolloFeedSplitReapplyVisible(void) {
    UITabBarController *tabs = sApolloDuoSplitTabs;
    if (![tabs isKindOfClass:[UITabBarController class]]) {
        UIViewController *main = ApolloMainTabBarController();
        if ([main isKindOfClass:[UITabBarController class]]) {
            tabs = (UITabBarController *)main;
            sApolloDuoSplitTabs = tabs;
        }
    }
    if (![tabs isKindOfClass:[UITabBarController class]]) {
        tabs = ApolloFeedSplitFindVisibleTabs();
        if (tabs) sApolloDuoSplitTabs = tabs;
    }
    ApolloLog(@"[FeedSplit] reapply tabs=%@ open=%d mode=%d", tabs ? NSStringFromClass(tabs.class) : @"nil", ApolloDuoRailIsActive(), ApolloDuoCurrentMode());
    if ([tabs isKindOfClass:[UITabBarController class]]) ApolloFeedSplitEnsure(tabs);
}
void ApolloFeedSplitReapplySoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloFeedSplitReapplyVisible(); });
}

static void ApolloFeedSplitRetryFromLaunch(NSInteger attempt) {
    ApolloFeedSplitReapplyVisible();
    if (attempt >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloFeedSplitRetryFromLaunch(attempt + 1);
    });
}

void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav) {
    ApolloLog(@"[FeedSplit] My Subreddits is hosted in the left Duo pane; opening Home feed in center");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloFeedSplitOpenHomeFeed(nav ?: ApolloFeedSplitPostsNavigation(sApolloDuoSplitTabs));
    });
}

%group ApolloDuoFeedSplitTabs
%hook UITabBarController
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloFeedSplitEnsure((UITabBarController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedSplitEnsure((UITabBarController *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    ApolloFeedSplitEnsure((UITabBarController *)self);
}
%end
%end

%group ApolloDuoFeedSplitNavigation
%hook _TtC6Apollo26ApolloNavigationController
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (ApolloDuoSplitIsOpen() && viewController &&
        strstr(class_getName(viewController.class), "CommentsViewController") != NULL) {
        ApolloDuoSplitHost *host = objc_getAssociatedObject(sApolloDuoSplitTabs, &kApolloDuoSplitHostKey);
        if (host) { [host showDetailViewController:viewController]; return; }
    }
    %orig;
}
%end
%end

%ctor {
    %init(ApolloDuoFeedSplitTabs);
    if (objc_getClass("ASTableView")) %init(ApolloDuoFeedSplitTable);
    if (objc_getClass("_TtC6Apollo26ApolloNavigationController")) %init(ApolloDuoFeedSplitNavigation);
    ApolloLog(@"[FeedSplit] open Duo three-pane host installed");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloFeedSplitRetryFromLaunch(0);
    });
}
