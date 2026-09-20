// ApolloDuoBook.xm
//
// First-slice Duo book layout: feed | comments on fully-open landscape
// and mid-open book postures. Closed portrait Duo and regular iPhone
// keep the frozen ApolloDuoV1 single-pane path (stock tab bar when
// Closed; Open rail / Subs chrome untouched).
//
// Do not re-enable ApolloFeedSplit's in-nav column pin. This file only
// intercepts feed → comments pushes and parks the post in the sibling
// host from ApolloDuoBook.m.
//
// Rotate / size-class: Begin/End around every transition so Sync /
// ApplyFrames / ShowDetail cannot re-enter from layout. Hosting is
// idempotent — the same comments VC or post is never wrapped again.

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloDuoBook.h"
#import "ApolloDuoCompatibility.h"

@interface _TtC6Apollo26ApolloNavigationController : UINavigationController
@end

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

static void ApolloDuoBookWatchTransition(id<UIViewControllerTransitionCoordinator> coordinator) {
    ApolloDuoBookBeginSizeTransition();
    if (!coordinator) {
        ApolloDuoBookEndSizeTransition();
        return;
    }
    [coordinator animateAlongsideTransition:nil
                                 completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoBookEndSizeTransition();
    }];
}

%group ApolloDuoBookTabs

%hook _TtC6Apollo22ApolloTabBarController

- (void)setSelectedViewController:(UIViewController *)viewController {
    %orig;
    if (ApolloDuoBookShouldApplyFrames()) {
        ApolloDuoBookSync();
    }
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    %orig;
    if (ApolloDuoBookShouldApplyFrames()) {
        ApolloDuoBookSync();
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    ApolloDuoBookWatchTransition(coordinator);
    %orig;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    if (!previous) return;
    if (previous.horizontalSizeClass != self.traitCollection.horizontalSizeClass
        || previous.verticalSizeClass != self.traitCollection.verticalSizeClass) {
        ApolloDuoBookBeginSizeTransition();
        ApolloDuoBookEndSizeTransition();
    }
}

%end

%end

%hook _TtC6Apollo26ApolloNavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (ApolloDuoBookAdoptPush((UINavigationController *)self, viewController)) {
        return;
    }
    %orig;
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    if (ApolloDuoBookAdoptPush((UINavigationController *)self, viewController)) {
        return;
    }
    %orig;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    ApolloDuoBookWatchTransition(coordinator);
    %orig;
}

%end

%group ApolloDuoBookMedia

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (ApolloDuoBookShouldApplyFrames()) {
        ApolloDuoBookSync();
    }
}

%end

%end

%ctor {
    Class nav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!nav) {
        ApolloLog(@"[DuoBook] ApolloNavigationController missing; book split inactive");
        return;
    }
    %init;
    Class tabs = objc_getClass("_TtC6Apollo22ApolloTabBarController");
    if (tabs) {
        %init(ApolloDuoBookTabs);
    }
    Class media = objc_getClass("_TtC6Apollo21MediaViewerController");
    if (media) {
        %init(ApolloDuoBookMedia);
    }
    ApolloLog(@"[DuoBook] hook installed (feed|comments on Open + mid-open book; Closed/Phone stock)");
}
