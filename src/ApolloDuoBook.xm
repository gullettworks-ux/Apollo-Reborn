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

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloDuoBook.h"
#import "ApolloDuoCompatibility.h"

@interface _TtC6Apollo26ApolloNavigationController : UINavigationController
@end

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

%group ApolloDuoBookTabs

%hook _TtC6Apollo22ApolloTabBarController

- (void)setSelectedViewController:(UIViewController *)viewController {
    %orig;
    ApolloDuoBookSync();
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    %orig;
    ApolloDuoBookSync();
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    [coordinator animateAlongsideTransition:nil
                                 completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoBookSync();
    }];
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

%end

%group ApolloDuoBookMedia

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ApolloDuoBookSync();
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
