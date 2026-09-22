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
#import "ApolloSubredditInfoCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloUserProfileCache.h"

static char kApolloDuoSplitHostKey;
static char kApolloDuoSplitOriginalSuperviewKey;
static char kApolloDuoSplitOriginalFrameKey;
static char kApolloDuoSplitInsetsClearedKey;
static BOOL sApolloDuoSplitAttaching = NO;
static __weak UITabBarController *sApolloDuoSplitTabs = nil;
static NSUInteger sApolloDuoSplitAttachRetries = 0;
static char kApolloDuoSplitRelayoutKey;
static char kApolloDuoSplitFeedRelayoutKey;
// Profile and Settings are whole tabs, not panes. While one of them is
// showing, the split host steps aside (stock tabs plus the rail take over)
// until the user returns to the feed tab.
static BOOL sApolloDuoSplitSuspended = NO;
@class ApolloDuoSplitHost;
static void ApolloFeedSplitMaskFeedTransition(ApolloDuoSplitHost *host);
static UINavigationController *ApolloFeedSplitPostsNavigation(UITabBarController *tabs);
static void ApolloFeedSplitOpenHomeFeed(UINavigationController *nav);
static void ApolloFeedSplitFillDetailScrollViews(UIView *view);
static BOOL ApolloFeedSplitCancelPhantomTrailingSafeArea(UIViewController *vc);
static void ApolloFeedSplitWidenDetailSoon(void);
static void ApolloFeedSplitDetach(UITabBarController *tabs);
static BOOL ApolloFeedSplitHandleUtility(ApolloDuoSplitHost *host, NSString *title);
static void ApolloFeedSplitLogDetailFrames(ApolloDuoSplitHost *host);
static void ApolloFeedSplitDumpDetailTree(UIView *view, CGFloat targetWidth, NSInteger depth);
static BOOL ApolloDuoSplitIsOpen(void);

// Apollo reserves room at the top of its lists for its own navigation bar
// and status bar. The host draws its own header, so that room shows up as a
// blank band under it. Drop the reserved space, and if the list was resting
// at the old top position, move it to the new top so the first row sits
// directly under the header. Only acts on a list resting at that position,
// so pull-to-refresh and normal scrolling are untouched.
static void ApolloFeedSplitPinScrollTop(UIScrollView *scroll) {
    if (!scroll) return;
    CGFloat adjusted = 0.0;
    if (@available(iOS 11.0, *)) adjusted = scroll.adjustedContentInset.top;
    BOOL atRest = !scroll.isDragging && !scroll.isDecelerating;
    BOOL restingAtTop = fabs(scroll.contentOffset.y + adjusted) < 1.5;
    if (@available(iOS 11.0, *)) {
        scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    UIEdgeInsets inset = scroll.contentInset;
    if (fabs(inset.top) > 0.5) {
        inset.top = 0.0;
        scroll.contentInset = inset;
    }
    UIEdgeInsets indicator = scroll.scrollIndicatorInsets;
    if (fabs(indicator.top) > 0.5) {
        indicator.top = 0.0;
        scroll.scrollIndicatorInsets = indicator;
    }
    if (adjusted > 0.5 && atRest && restingAtTop) {
        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, 0.0);
    }
}

// Apollo's ASTableView recreates/layouts its visible cells after the host's
// pass. Apply the Duo width after Apollo's own layout has finished.
%group ApolloDuoFeedSplitTable
%hook ASTableView
- (void)layoutSubviews {
    %orig;
    if (!ApolloDuoSplitIsOpen()) return;
    UITableView *table = (UITableView *)self;
    UIView *splitHost = objc_getAssociatedObject(sApolloDuoSplitTabs, &kApolloDuoSplitHostKey);
    if (splitHost && [table isDescendantOfView:splitHost]) ApolloFeedSplitPinScrollTop(table);
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
    // Any OTHER scroll/collection view nested inside the outer table (image
    // gallery carousels, thumbnail strips, Texture ASCollectionView/
    // ASPagerNode-backed views) sizes its own cells independently of the
    // enclosing vertical table's width. Forcing those cells up to
    // inheritedWidth stretched each gallery page to the detail column's full
    // width while the collection view's own (narrower) frame stayed put, so
    // two pages ended up visible side by side instead of one full-bleed
    // page. Apollo is built on AsyncDisplayKit, whose collection/pager views
    // don't reliably present as UICollectionViewFlowLayout, so key off any
    // UIScrollView that isn't itself the table — not the layout class.
    if ([view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:[UITableView class]]
        && [NSStringFromClass(view.class) rangeOfString:@"TableView"].location == NSNotFound) {
        inheritedWidth = 0.0;
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
// built before the pane was widened stays narrow, leaving its content (text,
// thumbnails) wrapped/packed at the old width even after the cell's UIKit
// frame is stretched. relayoutItems/invalidateCalculatedLayout are declared
// on ASTableNode (the node), not on the _ASTableView (its backing UIKit
// view) that this walk actually finds — resolve the owning node the same
// way ApolloDuoRail.m does before invalidating.
static void ApolloFeedSplitRelayoutTables(UIView *view) {
    if (!view) return;
    if ([NSStringFromClass(view.class) rangeOfString:@"ASTableView"].location != NSNotFound) {
        id node = nil;
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            if ([view respondsToSelector:nodeSelectors[i]]) {
                node = ((id (*)(id, SEL))objc_msgSend)(view, nodeSelectors[i]);
                if (node) break;
            }
        }
        if (node) {
            SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
            if ([node respondsToSelector:invalidate]) {
                ((void (*)(id, SEL))objc_msgSend)(node, invalidate);
            }
            SEL relayout = NSSelectorFromString(@"relayoutItems");
            if ([node respondsToSelector:relayout]) {
                ((void (*)(id, SEL))objc_msgSend)(node, relayout);
            }
            SEL needsLayout = NSSelectorFromString(@"setNeedsLayout");
            if ([node respondsToSelector:needsLayout]) {
                ((void (*)(id, SEL))objc_msgSend)(node, needsLayout);
            }
        }
    }
    // NOTE: tried a beginUpdates/endUpdates branch here for plain UIKit
    // self-sizing cells (Subreddits directory rows sometimes cache an
    // oversized row height, leaving a dead gap below single-line text).
    // Reverted — it overcorrected in the open/book layout (rows became too
    // cramped) while doing nothing for portrait/Closed mode (which never
    // reaches this function at all, via a completely separate rail-overlay
    // code path in ApolloDuoRail.m). Needs a real fix in both places, not
    // a blind forced recalculation in just one.
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
@property (nonatomic, strong) UIScrollView *sidebarScroll;
@property (nonatomic, strong) UIView *feedColumn;
@property (nonatomic, strong) UIView *detailColumn;
@property (nonatomic, strong) UIView *feedSeparator;
@property (nonatomic, strong) UIView *detailSeparator;
@property (nonatomic, strong) UIView *sidebarHeader;
@property (nonatomic, strong) UIView *feedHeader;
@property (nonatomic, strong) UIView *detailHeader;
@property (nonatomic, strong) UILabel *detailHeaderTitle;
@property (nonatomic, strong) UINavigationController *detailNavigation;
@property (nonatomic, weak) UINavigationController *feedNavigation;
- (instancetype)initWithTabs:(UITabBarController *)tabs feed:(UINavigationController *)feed;
- (void)layoutColumns;
- (void)showDetailViewController:(UIViewController *)controller;
- (void)clearDetail;
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
// Stacking order among pinned-bottom items, 0 = flush at the very bottom,
// higher values stack upward from there (Settings=0, Profile=1, so Profile
// sits just above Settings rather than up in the scrollable list where it
// could get fat-fingered while scrolling through subreddits).
@property (nonatomic, assign) NSInteger pinnedOrder;
@end
@implementation ApolloDuoSplitSidebarButton
// Icon over label, stacked vertically and centered — re-examined the
// reference render closely: its rail items are a narrow icon-above-text
// column (house icon, "Home" text below, centered in a portrait-ish rounded
// box), not icon+label side by side. An earlier pass misread that as
// horizontal; this corrects it back.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    // A fixed icon box, not the image's own .size: that worked by accident
    // for SF Symbols (whose intrinsic size already matches their configured
    // point size) but a real downloaded subreddit icon is a full-resolution
    // photo — sized to its own pixel dimensions, it swallowed the whole
    // button. contentMode scales any source down (or up) to fit this box.
    const CGFloat icon = 22.0;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.frame = CGRectMake(floor((width - icon) * 0.5), 10.0, icon, icon);
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
        // performWithoutAnimation only suppresses UIView-level animation
        // blocks — it does nothing about Apollo's own internal IGListKit
        // diffing update, which appears to run its own animated
        // insert/delete transition on the feed table regardless, briefly
        // compositing the outgoing and incoming rows on top of each other.
        // Mask the transition instead of fighting it: hide the feed
        // instantly, let Apollo's animation run underneath invisibly, then
        // reveal once it's had time to finish.
        ApolloFeedSplitMaskFeedTransition(self.host);
        [UIView performWithoutAnimation:^{
            if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
                ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
            }
            ApolloFeedSplitOpenHomeFeed(ApolloFeedSplitPostsNavigation(tabs));
        }];
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
        // See the matching comment on the Home route above: this masks
        // Apollo's own animated IGListKit diffing transition, which runs
        // independent of our performWithoutAnimation wrapper.
        ApolloFeedSplitMaskFeedTransition(self.host);
        [UIView performWithoutAnimation:^{
            routed = ApolloRouteURLThroughApp(url);
            if (routed) [self.host layoutColumns];
        }];
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
    UIColor *onAccent = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    [button setTitleColor:selected ? onAccent : muted forState:UIControlStateNormal];
    button.tintColor = selected ? onAccent : muted;
    button.backgroundColor = selected ? accent : UIColor.clearColor;
}

// Real subreddit icon for a sidebar favorite row — same cache-then-fetch
// pattern already proven in ApolloSubredditHeaders.xm's header icon loading:
// user-set custom icon first, then the fetched community icon, downloaded
// through the shared image cache. Set with UIImageRenderingModeAlwaysOriginal
// (not the SF Symbols' template mode) so the icon's real colors show instead
// of being tinted like the plain nav glyphs — a "#" placeholder is generic
// and reads unpolished next to real subreddit branding.
static void ApolloDuoSplitApplySubredditIcon(ApolloDuoSplitSidebarButton *button, NSString *subredditName) {
    if (!button || subredditName.length == 0) return;
    UIImage *customIcon = [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:subredditName];
    if (customIcon) {
        [button setImage:[customIcon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                 forState:UIControlStateNormal];
        return;
    }
    void (^apply)(UIImage *) = ^(UIImage *image) {
        if (!image) return;
        [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                 forState:UIControlStateNormal];
    };
    ApolloSubredditInfo *cached = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
    ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
    if (cached.iconURL) {
        UIImage *icon = [imageCache cachedImageForURL:cached.iconURL];
        if (icon) { apply(icon); return; }
        __weak ApolloDuoSplitSidebarButton *weakButton = button;
        [imageCache requestImageForURL:cached.iconURL completion:^(UIImage *image) {
            apply(weakButton ? image : nil);
        }];
        return;
    }
    __weak ApolloDuoSplitSidebarButton *weakButton = button;
    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:subredditName completion:^(ApolloSubredditInfo *info) {
        ApolloDuoSplitSidebarButton *strongButton = weakButton;
        if (!strongButton || !info.iconURL) return;
        UIImage *icon = [imageCache cachedImageForURL:info.iconURL];
        if (icon) { apply(icon); return; }
        [imageCache requestImageForURL:info.iconURL completion:^(UIImage *image) {
            apply(weakButton ? image : nil);
        }];
    }];
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
    button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) {
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    ApolloDuoSplitStyleSidebarButton(button, selected);
    [button addTarget:target action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    // "number" marks a dynamically-added favorite-subreddit row (see
    // ApolloDuoSplitBuildSidebar) — replace its generic "#" placeholder with
    // the subreddit's real icon once available.
    if ([symbol isEqualToString:@"number"] && feedTitle.length > 0) {
        ApolloDuoSplitApplySubredditIcon(button, feedTitle);
    }
    return button;
}

// The app's current icon (default or active alternate), for the sidebar's
// branding header — same Info.plist-driven resolution UIApplication itself
// uses for alternateIconName.
static UIImage *ApolloDuoSplitAppIcon(void) {
    NSDictionary *icons = [NSBundle mainBundle].infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:[NSDictionary class]]) return nil;
    NSArray<NSString *> *iconFiles = nil;
    NSString *alternateName = [UIApplication sharedApplication].alternateIconName;
    if (alternateName.length > 0) {
        NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
        NSDictionary *iconInfo = [alternates isKindOfClass:[NSDictionary class]] ? alternates[alternateName] : nil;
        iconFiles = [iconInfo[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? iconInfo[@"CFBundleIconFiles"] : nil;
    }
    if (iconFiles.count == 0) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        iconFiles = [primary[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? primary[@"CFBundleIconFiles"] : nil;
    }
    NSString *iconName = iconFiles.lastObject;
    return iconName.length > 0 ? [UIImage imageNamed:iconName] : nil;
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

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = YES;
    [sidebar addSubview:scroll];
    host.sidebarScroll = scroll;

    // Four static nav buttons — Home, Popular, All, and Subreddits (which
    // opens the full subreddit directory in the feed pane on tap, same as
    // tapping the header's "+"). Not a live list of favorited subreddits
    // inline in the sidebar: that read as clutter rather than navigation —
    // a lean, predictable button list is what a permanent sidebar should be.
    // Frames are set in -layoutColumns (scrollable stack; Profile/Settings
    // pinned to the sidebar's own bottom, outside the scroll view).
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        @{ @"title": @"Subreddits", @"symbol": @"list.bullet",             @"route": @"apollo://subreddits",
           @"feed": @"My Subreddits", @"selectable": @YES },
        @{ @"title": @"Home",       @"symbol": @"house.fill",              @"route": @"apollo://home",
           @"feed": @"Home", @"selectable": @YES, @"selected": @YES },
        @{ @"title": @"Popular",    @"symbol": @"flame.fill",              @"route": @"apollo://reddit.com/r/popular",
           @"feed": @"Popular", @"selectable": @YES },
        @{ @"title": @"All",        @"symbol": @"globe.americas.fill",     @"route": @"apollo://reddit.com/r/all",
           @"feed": @"All", @"selectable": @YES },
    ]];
    // NOT added: Saved / History rows. apollo://saved and apollo://history
    // report success from ApolloRouteURLThroughApp but don't actually
    // navigate the feed pane (Apollo has no goToSavedTab/goToHistoryTab
    // selector — Saved/History are rows inside the Profile screen, backed by
    // SavedPostsCommentsViewController, which needs private pagination/
    // category state Profile sets up internally to construct correctly). A
    // button whose label doesn't match what tapping it does is worse than no
    // button — reachable via Profile for now until that VC is wired up
    // properly.
    for (NSDictionary *item in items) {
        ApolloDuoSplitSidebarButton *button =
            ApolloDuoSplitMakeSidebarButton(target, item[@"title"], item[@"symbol"], item[@"route"],
                                            item[@"feed"], [item[@"selectable"] boolValue],
                                            [item[@"selected"] boolValue]);
        [scroll addSubview:button];
    }

    // Profile and Settings both pin to the sidebar's own bottom, below the
    // scrollable subreddit list — not mixed into the scroll content, where
    // Profile previously sat right above the favorites and was an easy
    // accidental tap while scrolling through subreddits.
    ApolloDuoSplitSidebarButton *profile =
        ApolloDuoSplitMakeSidebarButton(target, @"Profile", @"person.crop.circle.fill",
                                        @"apollo://profile", nil, NO, NO);
    profile.pinnedBottom = YES;
    profile.pinnedOrder = 1;
    [sidebar addSubview:profile];

    ApolloDuoSplitSidebarButton *settings =
        ApolloDuoSplitMakeSidebarButton(target, @"Settings", @"gearshape.fill",
                                        @"apollo://settings", nil, NO, NO);
    settings.pinnedBottom = YES;
    settings.pinnedOrder = 0;
    [sidebar addSubview:settings];
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
    // phone toolbar from consuming the center column. Sidebar header is
    // branding (app icon + "Apollo"), matching the reference layout, not an
    // add-subreddit affordance — that lives in the real directory the
    // Subreddits nav item opens, which has its own native "+".
    self.sidebarHeader = ApolloDuoSplitHeader(@"Apollo", self.sidebar.backgroundColor);
    self.feedHeader = ApolloDuoSplitHeader(@"Home", self.feedColumn.backgroundColor);
    self.detailHeader = ApolloDuoSplitHeader(@"Comments", self.detailColumn.backgroundColor);
    self.detailHeaderTitle = [self.detailHeader viewWithTag:9001];
    [self.sidebar addSubview:self.sidebarHeader];
    [self.feedColumn addSubview:self.feedHeader];
    [self.detailColumn addSubview:self.detailHeader];

    UIImageView *brandIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    brandIcon.tag = 9003;
    brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    brandIcon.layer.cornerRadius = 6.0;
    brandIcon.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) {
        brandIcon.layer.cornerCurve = kCACornerCurveContinuous;
    }
    brandIcon.image = ApolloDuoSplitAppIcon();
    [self.sidebarHeader addSubview:brandIcon];
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
    // Branding header (app icon + "Apollo") back above the nav list, per the
    // reference layout — distinct from the earlier "MY SUBREDDITS" + add
    // button header, which was redundant with the Subreddits nav item below
    // it. This one is pure identity, not a duplicate control.
    self.sidebarHeader.hidden = NO;
    {
        CGFloat topInset = MAX(self.safeAreaInsets.top, 26.0);
        CGFloat headerHeight = 52.0 + topInset;
        CGFloat bottomInset = MAX(self.safeAreaInsets.bottom, 12.0);
        // 60pt was actually too short for its own content: the button's
        // icon+label layout (icon at y=10..32, label at y=38..66) needs
        // ~66pt, so labels were overflowing the row's own bounds, and a 2pt
        // gap left almost no breathing room between rows — both read as
        // "squished." 72pt/6pt (matching ApolloDuoRail.m's proven
        // icon-over-label proportions) actually fits the content.
        const CGFloat itemHeight = 72.0;
        const CGFloat itemGap = 6.0;
        CGFloat itemWidth = MAX(0.0, sidebarWidth - 16.0);

        NSMutableArray<ApolloDuoSplitSidebarButton *> *pinned = [NSMutableArray array];
        for (UIView *view in self.sidebar.subviews) {
            if ([view isKindOfClass:[ApolloDuoSplitSidebarButton class]]
                && ((ApolloDuoSplitSidebarButton *)view).pinnedBottom) {
                [pinned addObject:(ApolloDuoSplitSidebarButton *)view];
            }
        }
        [pinned sortUsingComparator:^NSComparisonResult(ApolloDuoSplitSidebarButton *a, ApolloDuoSplitSidebarButton *b) {
            return a.pinnedOrder < b.pinnedOrder ? NSOrderedAscending
                 : a.pinnedOrder > b.pinnedOrder ? NSOrderedDescending : NSOrderedSame;
        }];
        CGFloat pinnedHeight = pinned.count > 0 ? (CGFloat)pinned.count * itemHeight + 8.0 : 0.0;
        CGFloat scrollY = headerHeight;
        CGFloat scrollHeight = MAX(0.0, height - scrollY - bottomInset - pinnedHeight);
        self.sidebarScroll.frame = CGRectMake(0.0, scrollY, sidebarWidth, scrollHeight);

        CGFloat y = 8.0;
        for (UIView *view in self.sidebarScroll.subviews) {
            if (![view isKindOfClass:[ApolloDuoSplitSidebarButton class]]) continue;
            view.frame = CGRectMake(8.0, y, itemWidth, itemHeight);
            y += itemHeight + itemGap;
        }
        self.sidebarScroll.contentSize = CGSizeMake(sidebarWidth, y + 8.0);

        CGFloat pinnedY = height - bottomInset - itemHeight;
        for (ApolloDuoSplitSidebarButton *item in pinned) {
            item.frame = CGRectMake(8.0, pinnedY, itemWidth, itemHeight);
            pinnedY -= itemHeight;
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
        BOOL isSidebar = header == self.sidebarHeader;
        // The sidebar header leads with the app icon (brandIcon, tag 9003),
        // so its label starts further in than the feed/detail headers' bare
        // text titles.
        CGFloat leading = isSidebar ? 38.0 : 18.0;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = isSidebar ? 0.6 : 0.68;
        label.frame = CGRectMake(leading, topInset + 8.0, MAX(0.0, CGRectGetWidth(header.bounds) - leading - 8.0), 34.0);
        rule.frame = CGRectMake(0.0, headerHeight - 1.0, CGRectGetWidth(header.bounds), 1.0);
    }
    UIImageView *brandIcon = [self.sidebarHeader viewWithTag:9003];
    brandIcon.frame = CGRectMake(8.0, topInset + 11.0, 24.0, 24.0);
    NSArray *feedButtons = @[[self.feedHeader viewWithTag:9101], [self.feedHeader viewWithTag:9102]];
    feedButtons = (feedButtons[0] && feedButtons[1]) ? feedButtons : @[];
    if (feedButtons.count == 2) {
        [feedButtons[0] setFrame:CGRectMake(feedWidth - 92.0, topInset + 6.0, 40.0, 40.0)];
        [feedButtons[1] setFrame:CGRectMake(feedWidth - 48.0, topInset + 6.0, 40.0, 40.0)];
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
        // See matching comment on the feed-column call: reapplying isn't
        // redundant (UIKit resets additionalSafeAreaInsets on its own
        // timing), and when it actually had to reapply, already-measured
        // cells need a forced relayout the dedup key below wouldn't trigger
        // on its own.
        if (ApolloFeedSplitCancelPhantomTrailingSafeArea(detailVisible)) {
            objc_setAssociatedObject(self, &kApolloDuoSplitRelayoutKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
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
            // UIKit resets additionalSafeAreaInsets on its own view controller
            // lifecycle timing (e.g. leaving and returning to this tab), so a
            // safe area that was already cancelled can come back — reapplying
            // it here is necessary, not redundant. When it actually had to
            // reapply, cells that were already created/measured under the
            // phantom-narrow width need a fresh relayout too, so clear the
            // dedup key to force one below even though (visible, width)
            // hasn't changed — that's what the dedup key was tracking, and
            // this specific staleness isn't captured by either of those.
            if (ApolloFeedSplitCancelPhantomTrailingSafeArea(visible)) {
                objc_setAssociatedObject(self, &kApolloDuoSplitFeedRelayoutKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            // The detail/comments column got this widen treatment from the
            // start; the feed column never did, so its native post rows
            // stayed sized for whatever narrower width they were last
            // measured at — content (thumbnail, text) packed to the left
            // with a dead gap of blank space before the column's actual
            // right edge, instead of filling it.
            ApolloFeedSplitFillDetailScrollViews(visible.view);
            ApolloFeedSplitWidenTableCells(visible.view, 0.0);
            NSString *feedRelayoutKey = [NSString stringWithFormat:@"%p-%.0f", visible,
                                         CGRectGetWidth(visibleFrame)];
            if (![feedRelayoutKey isEqualToString:objc_getAssociatedObject(self, &kApolloDuoSplitFeedRelayoutKey)]) {
                objc_setAssociatedObject(self, &kApolloDuoSplitFeedRelayoutKey, feedRelayoutKey,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloFeedSplitRelayoutTables(visible.view);
                __weak UIViewController *weakVisible = visible;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *strongVisible = weakVisible;
                    if (strongVisible.isViewLoaded) ApolloFeedSplitRelayoutTables(strongVisible.view);
                });
            }
        }
    }
    ApolloFeedSplitLogDetailFrames(self);
}

// "+" in the sidebar header opens Apollo's real, full subreddit directory
// (search, A-Z index, favorites/moderator/multireddit sections, its own
// real add-subreddit affordance) into the feed pane — the sidebar's
// favorites shortlist is a curated subset, not a replacement for it.
- (void)addSubreddit {
    UINavigationController *nav = self.feedNavigation;
    if (nav.viewControllers.count > 1) [nav popToRootViewControllerAnimated:NO];
    dispatch_async(dispatch_get_main_queue(), ^{ [self layoutColumns]; });
}
// Same hand-back-to-stock-tabs pattern as the Profile route: Apollo's real
// search UI isn't something this split host hosts, so detach and let the
// native tab bar controller show it. This was a no-op stub before — search
// silently did nothing when tapped.
- (void)searchFeed {
    UITabBarController *tabs = self.tabs;
    sApolloDuoSplitSuspended = YES;
    ApolloFeedSplitDetach(tabs);
    if ([tabs respondsToSelector:@selector(goToSearchTab)]) {
        ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToSearchTab));
    }
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoRailSync(); });
}
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

// The detail header's "<" always reset the whole pane to blank, discarding
// any deeper navigation (e.g. tapping a commenter's profile, which pushes a
// second view controller onto detailNavigation) instead of just going back
// one step — from the pushed screen, "back" looked like it wasn't working
// because it skipped straight past the comments screen you were expecting
// to land on. Pop one level when there's somewhere to pop to; only clear to
// a blank placeholder once already at the root.
- (void)clearDetail {
    if (self.detailNavigation.viewControllers.count > 1) {
        [self.detailNavigation popViewControllerAnimated:NO];
        return;
    }
    UIViewController *placeholder = [UIViewController new];
    placeholder.view.backgroundColor = ApolloDuoSplitPageColor();
    [self.detailNavigation setViewControllers:@[placeholder] animated:NO];
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

// Apollo's own IGListKit-driven feed swap runs its own animated
// insert/delete diffing transition independent of our
// performWithoutAnimation wrapper, briefly compositing the outgoing and
// incoming rows on top of each other (visible as garbled/overlapping text
// for a frame or two when switching Home/Popular/All quickly). Rather than
// try to intercept and force that diffing update to be non-animated, hide
// the feed instantly and reveal it once Apollo's transition has had time to
// finish — trades a brief blank flash for the double-render glitch, which
// reads as an intentional page-turn rather than a bug. A generation token
// guards against a rapid second tap firing an earlier fade-in after a
// newer hide, which would flash the still-transitioning content early.
static char kApolloDuoSplitFeedMaskGenerationKey;
static void ApolloFeedSplitMaskFeedTransition(ApolloDuoSplitHost *host) {
    UIView *feedView = host.feedNavigation.view;
    if (!feedView) return;
    feedView.alpha = 0.0;
    NSUInteger generation = [objc_getAssociatedObject(host, &kApolloDuoSplitFeedMaskGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(host, &kApolloDuoSplitFeedMaskGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ApolloDuoSplitHost *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *strongHost = weakHost;
        if (!strongHost) return;
        NSUInteger current = [objc_getAssociatedObject(strongHost, &kApolloDuoSplitFeedMaskGenerationKey) unsignedIntegerValue];
        if (current != generation) return;
        // Re-run the full width-fix pass (safe area cancellation, cell
        // widening, relayout) right before revealing, on whatever content
        // actually landed — rather than trust that a fix scheduled earlier
        // already caught up with it by now.
        [strongHost layoutColumns];
        [UIView animateWithDuration:0.15 animations:^{
            strongHost.feedNavigation.view.alpha = 1.0;
        }];
    });
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
    // feed is Apollo's own real navigation controller, shared with
    // portrait/Closed mode — layoutColumns hides its navigation bar to make
    // room for our book-layout header, but nothing ever set it back. Left
    // hidden, Closed/portrait mode loses its back button and title bar
    // entirely, since it's the same controller instance.
    [feed setNavigationBarHidden:NO animated:NO];
    [host removeFromSuperview];
    objc_setAssociatedObject(tabs, &kApolloDuoSplitHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalSuperviewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(feed, &kApolloDuoSplitOriginalFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(feed, &kApolloDuoSplitInsetsClearedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Confirmed via RE (AsyncDisplayKit's _NodeConstrainedSizeForScrollDirection):
// Texture derives a table's default per-row constrainedSize from
// bounds.width minus the scroll view's *adjusted* content inset, which
// folds in safeAreaInsets. On this dual-screen canvas, a table confined to
// one physical panel gets a phantom ~84pt trailing safeAreaInsets (matches
// the hinge/edge exactly) even though it's UIKit/DeviceKit's own inherent
// value, not something our code sets — contentInsetAdjustmentBehavior
// doesn't stick against it, and Texture reads the derived inset via a path
// that bypasses -adjustedContentInset's public getter (hooking it has no
// effect), so neither approach works. additionalSafeAreaInsets is the
// documented, supported way to cancel a safe area value UIKit computed on
// its own — it feeds the real internal computation, not just a getter
// facade. No one-shot guard: the detail column's caller unconditionally
// resets additionalSafeAreaInsets to zero every pass before calling this,
// so re-measuring from that clean baseline each time is correct, not
// compounding. Once compensated, the measured safeAreaInsets.right reads
// back near zero and the >0.5 guard below makes this a no-op — a stable
// fixed point, not drift.
static BOOL ApolloFeedSplitCancelPhantomTrailingSafeArea(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    CGFloat right = vc.view.safeAreaInsets.right;
    if (right > 0.5) {
        UIEdgeInsets extra = vc.additionalSafeAreaInsets;
        extra.right -= right;
        vc.additionalSafeAreaInsets = extra;
        // additionalSafeAreaInsets doesn't propagate into safeAreaInsets
        // synchronously within this run-loop turn — force it now so the
        // relayout the caller triggers right after this returns actually
        // reads the corrected value instead of racing it.
        [vc.view layoutIfNeeded];
        ApolloLog(@"[FeedSplit] cancelled phantom trailing safe area %.1f on %@",
                  right, NSStringFromClass(vc.class));
        return YES;
    }
    return NO;
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

// Apollo never implements a custom constrainedSize delegate for its
// IGListKit/Texture-backed tables (confirmed via RE — no
// -tableNode:constrainedSizeForRow... override exists anywhere in the
// binary), so Texture's own default per-row measurement is in play, which
// derives its width from the owning ASTableNode's OWN tracked frame — not
// from the backing _ASTableView's raw UIKit .frame/.bounds. Setting .frame
// directly on the view (as this file does throughout, for good reason: it's
// the only thing directly reachable by walking the UIKit view hierarchy)
// resizes what's on screen but never tells the ASDisplayNode object itself
// that its size changed, since Texture expects resizes to go through the
// node. Call this right after any .frame assignment on a view that might be
// Texture-backed so the node's own frame — and therefore every measurement
// pass that reads it — actually reflects the new size.
static void ApolloFeedSplitSyncNodeFrame(UIView *view) {
    if (!view) return;
    SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
    for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
        if ([view respondsToSelector:nodeSelectors[i]]) {
            id node = ((id (*)(id, SEL))objc_msgSend)(view, nodeSelectors[i]);
            if (node && [node respondsToSelector:@selector(setFrame:)]) {
                ((void (*)(id, SEL, CGRect))objc_msgSend)(node, @selector(setFrame:), view.frame);
            }
            return;
        }
    }
}

static void ApolloFeedSplitFillDetailScrollViews(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UIScrollView class]] && view.superview) {
        UIScrollView *scroll = (UIScrollView *)view;
        view.translatesAutoresizingMaskIntoConstraints = YES;
        view.frame = view.superview.bounds;
        ApolloFeedSplitSyncNodeFrame(view);
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
                ApolloFeedSplitSyncNodeFrame(child);
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
BOOL ApolloFeedSplitSuspended(void) {
    return sApolloDuoSplitSuspended;
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

// ApolloFeedSplitMaskFeedTransition only fires from our own sidebar's tap
// handler. Tapping a row directly inside Apollo's native Subreddits
// directory (Home/Popular/All/a specific subreddit) reaches the same
// animated IGListKit feed-swap transition through a completely different
// call path — Apollo's own row selection, never routed through our
// sidebar — so it was never masked, leaving the same overlap/ghosting
// glitch visible there.
%group ApolloDuoFeedSplitListSelection
%hook _TtC6Apollo24RedditListViewController
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    if (ApolloDuoSplitIsOpen()) {
        ApolloDuoSplitHost *host = objc_getAssociatedObject(sApolloDuoSplitTabs, &kApolloDuoSplitHostKey);
        if (host) ApolloFeedSplitMaskFeedTransition(host);
    }
    %orig;
}
%end
%end

%ctor {
    %init(ApolloDuoFeedSplitTabs);
    if (objc_getClass("ASTableView")) %init(ApolloDuoFeedSplitTable);
    if (objc_getClass("_TtC6Apollo26ApolloNavigationController")) %init(ApolloDuoFeedSplitNavigation);
    if (objc_getClass("_TtC6Apollo24RedditListViewController")) %init(ApolloDuoFeedSplitListSelection);
    ApolloLog(@"[FeedSplit] open Duo three-pane host installed");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloFeedSplitRetryFromLaunch(0);
    });
}
