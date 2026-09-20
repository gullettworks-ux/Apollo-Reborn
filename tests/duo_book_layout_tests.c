#include "ApolloDuoBookLayout.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;

static void Check(int condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static int Near(double actual, double expected) {
    return fabs(actual - expected) < 0.51;
}

int main(void) {
    Check(ApolloDuoHingeStatusFromUIKit(1) == ApolloDuoHingeClosed,
          "UIKit status 1 is closed");
    Check(ApolloDuoHingeStatusFromUIKit(2) == ApolloDuoHingePartiallyOpen,
          "UIKit status 2 is mid-open / partiallyOpen");
    Check(ApolloDuoHingeStatusFromUIKit(3) == ApolloDuoHingeFullyOpen,
          "UIKit status 3 is fullyOpen");
    Check(ApolloDuoHingeStatusFromUIKit(0) == ApolloDuoHingeUnknown,
          "UIKit status 0 is unknown");
    Check(ApolloDuoHingeStatusFromUIKit(99) == ApolloDuoHingeUnknown,
          "an unrecognized UIKit status does not enable a book posture");

    Check(ApolloDuoBookPostureFromState(ApolloDuoModePhone, ApolloDuoHingeUnknown)
              == ApolloDuoBookPosturePhone,
          "regular iPhone stays Phone even with no hinge API");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModePhone, ApolloDuoHingePartiallyOpen)
              == ApolloDuoBookPosturePhone,
          "a hinge report cannot turn a regular iPhone into a book");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModePhone, ApolloDuoHingeFullyOpen)
              == ApolloDuoBookPosturePhone,
          "fully-open hinge is ignored on Phone");

    Check(ApolloDuoBookPostureFromState(ApolloDuoModeClosed, ApolloDuoHingeUnknown)
              == ApolloDuoBookPostureClosed,
          "Closed Duo without a hinge API stays Closed");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeClosed, ApolloDuoHingeClosed)
              == ApolloDuoBookPostureClosed,
          "closed hinge on a Closed window is Closed");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeClosed, ApolloDuoHingeFullyOpen)
              == ApolloDuoBookPostureClosed,
          "inner portrait + fully-open hinge stays Closed (no landscape split)");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeClosed, ApolloDuoHingePartiallyOpen)
              == ApolloDuoBookPostureMidOpenBook,
          "partially-open hinge on a Duo window is mid-open book");

    Check(ApolloDuoBookPostureFromState(ApolloDuoModeOpen, ApolloDuoHingeUnknown)
              == ApolloDuoBookPostureFullyOpen,
          "Open landscape without a hinge API is fully-open (sim / older SDK)");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeOpen, ApolloDuoHingeFullyOpen)
              == ApolloDuoBookPostureFullyOpen,
          "Open landscape + fullyOpen hinge is fully-open");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeOpen, ApolloDuoHingePartiallyOpen)
              == ApolloDuoBookPostureMidOpenBook,
          "Open landscape + partiallyOpen hinge is mid-open book");
    Check(ApolloDuoBookPostureFromState(ApolloDuoModeOpen, ApolloDuoHingeClosed)
              == ApolloDuoBookPostureFullyOpen,
          "Open window is fully-open even when the Duo sim hinge reports Closed");

    Check(!ApolloDuoBookPostureAllowsSplit(ApolloDuoBookPosturePhone),
          "Phone posture cannot split");
    Check(!ApolloDuoBookPostureAllowsSplit(ApolloDuoBookPostureClosed),
          "Closed posture cannot split");
    Check(ApolloDuoBookPostureAllowsSplit(ApolloDuoBookPostureMidOpenBook),
          "mid-open book can split");
    Check(ApolloDuoBookPostureAllowsSplit(ApolloDuoBookPostureFullyOpen),
          "fully-open can split");

    Check(!ApolloDuoBookSplitShouldEnable(ApolloDuoBookPostureFullyOpen, 400.0),
          "a cover-narrow canvas cannot host two 320pt columns");
    Check(!ApolloDuoBookSplitShouldEnable(ApolloDuoBookPostureMidOpenBook,
                                          (double)ApolloFeedSplitMinRegularWidth - 1.0),
          "mid-open below two-column minimum stays single-pane");
    Check(ApolloDuoBookSplitShouldEnable(ApolloDuoBookPostureMidOpenBook,
                                         (double)ApolloFeedSplitMinRegularWidth),
          "mid-open at two-column minimum may split");
    Check(ApolloDuoBookSplitShouldEnable(ApolloDuoBookPostureFullyOpen, 1013.0),
          "fully-open inner usable width splits");

    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModePhone,
                                                   ApolloDuoHingeUnknown,
                                                   390.0, 844.0),
          "phone portrait never splits");
    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModePhone,
                                                   ApolloDuoHingeUnknown,
                                                   932.0, 430.0),
          "Max landscape without a Duo hint stays single-pane");
    Check(!ApolloDuoBookSplitShouldEnableForCanvas(ApolloDuoModePhone,
                                                   ApolloDuoHingeUnknown,
                                                   390.0, 844.0, 1),
          "phone portrait stays single-pane even with a Duo hint");
    Check(!ApolloDuoBookSplitShouldEnableForCanvas(ApolloDuoModePhone,
                                                   ApolloDuoHingeUnknown,
                                                   932.0, 430.0, 0),
          "Max landscape without glass/hinge/dual/rail does not split");
    Check(ApolloDuoBookSplitShouldEnableForCanvas(ApolloDuoModePhone,
                                                  ApolloDuoHingeUnknown,
                                                  951.0, 430.0, 1),
          "Duo sim ~951pt landscape splits even though V1 mode is Phone");
    Check(ApolloDuoBookPostureFromCanvas(ApolloDuoModePhone,
                                         ApolloDuoHingeClosed,
                                         951.0, 430.0, 1)
              == ApolloDuoBookPostureFullyOpen,
          "951pt landscape + Duo hint is FullyOpen under the 1000pt Phone gate");
    Check(ApolloDuoBookPostureFromCanvas(ApolloDuoModePhone,
                                         ApolloDuoHingeUnknown,
                                         390.0, 844.0, 1)
              == ApolloDuoBookPosturePhone,
          "phone portrait + Duo hint stays Phone");
    Check(ApolloDuoBookPostureFromCanvas(ApolloDuoModeClosed,
                                         ApolloDuoHingeUnknown,
                                         744.0, 1133.0, 1)
              == ApolloDuoBookPostureClosed,
          "portrait Closed stays Closed even with a Duo hint");
    Check(!ApolloDuoBookSplitShouldEnableForCanvas(ApolloDuoModeClosed,
                                                   ApolloDuoHingeUnknown,
                                                   744.0, 1133.0, 1),
          "portrait Closed never splits");
    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeClosed,
                                                   ApolloDuoHingeUnknown,
                                                   400.0, 900.0),
          "cover Closed never splits");
    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeClosed,
                                                   ApolloDuoHingeUnknown,
                                                   744.0, 1133.0),
          "inner portrait Closed never splits without a mid-open hinge");
    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeClosed,
                                                   ApolloDuoHingePartiallyOpen,
                                                   400.0, 900.0),
          "mid-open hinge on a cover-narrow window still does not split");
    Check(ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeClosed,
                                                  ApolloDuoHingePartiallyOpen,
                                                  744.0, 1133.0),
          "mid-open book on a wide-enough inner portrait may split");
    Check(ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeOpen,
                                                  ApolloDuoHingeUnknown,
                                                  1133.0, 744.0),
          "fully-open landscape splits without a hinge API");
    Check(ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeOpen,
                                                  ApolloDuoHingePartiallyOpen,
                                                  1133.0, 744.0),
          "mid-open book on a landscape inner splits");
    Check(ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeOpen,
                                                  ApolloDuoHingeClosed,
                                                  1133.0, 744.0),
          "wide Open window splits even if the hinge still says Closed");

    Check(Near(ApolloDuoBookExtraLeftForMode(ApolloDuoModeOpen), 0.0),
          "Open book extraLeft is 0 (no reserved rail column)");
    Check(Near(ApolloDuoBookExtraLeftForMode(ApolloDuoModeClosed), 0.0),
          "Closed book extraLeft is 0 (no reserved rail column)");
    Check(Near(ApolloDuoBookExtraLeftForMode(ApolloDuoModePhone), 0.0),
          "Phone-mode book extraLeft is 0 (no reserved rail column)");
    Check(ApolloDuoBookShouldWriteFrames(0, 0, 0),
          "book may write frames when idle");
    Check(!ApolloDuoBookShouldWriteFrames(1, 0, 0),
          "book must not write frames while an overlay is up");
    Check(!ApolloDuoBookShouldWriteFrames(0, 1, 0),
          "book must not write frames during a size-class / rotate transition");
    Check(!ApolloDuoBookShouldWriteFrames(0, 0, 1),
          "book must not re-enter ApplyFrames from layout");
    Check(!ApolloDuoBookShouldWriteFrames(1, 1, 1),
          "overlay + transition + in-flight apply all block frame writes");

    Check(ApolloDuoBookLeftPaneAllowsClass("_TtC6Apollo19PostsViewController"),
          "the posts feed may occupy the left pane");
    Check(ApolloDuoBookLeftPaneAllowsClass("_TtC6Apollo32SavedPostsCommentsViewController"),
          "Saved Posts list may occupy the left pane");
    Check(!ApolloDuoBookLeftPaneAllowsClass("_TtC6Apollo22CommentsViewController"),
          "comments must not be pinned into the left feed frame");
    Check(!ApolloDuoBookLeftPaneAllowsClass("_TtC6Apollo21MediaViewerController"),
          "MediaViewer is an overlay, not a left-pane controller");
    Check(!ApolloDuoBookLeftPaneAllowsClass("_TtC6Apollo26UserCommentsViewController"),
          "user comments stay on the right host");

    Check(Near(ApolloDuoBookExtraRightForMode(ApolloDuoModeOpen),
               (double)ApolloDuoBookDetailTrailingChrome),
          "book extraRight is the trailing bezel chrome, not a rail");
    Check(ApolloDuoBookExtraRightForMode(ApolloDuoModePhone)
              == ApolloDuoBookExtraRightForMode(ApolloDuoModeOpen),
          "Phone-mode book (951pt Duo sim) gets the same trailing chrome");
    Check(ApolloDuoBookExtraRightForMode(ApolloDuoModeOpen) + 0.5
              < ApolloDuoRailContentLeftInset(),
          "Open extraRight is not a second 120pt rail column");
    Check(ApolloDuoBookJumpMaxX(500.0) + 0.5
              <= 500.0 - (double)ApolloDuoBookDetailCornerGutter + 0.5,
          "jump FAB stays inside the detail corner gutter");
    Check(ApolloDuoBookJumpMaxY(400.0) + 0.5
              <= 400.0 - (double)ApolloDuoBookDetailBottomChrome + 0.5,
          "jump FAB stays above the detail bottom chrome");

    ApolloFeedSplitFrames open = ApolloDuoBookFramesForMode(1133.0, 744.0,
                                                            ApolloDuoModeOpen);
    Check(open.showsDetail, "Open book always exposes a right pane (placeholder or post)");
    Check(open.feed.x + 0.5 < 1.0,
          "Open feed uses the full half-pane; no leading rail column");
    Check(Near(open.feed.width,
               1133.0 * 0.5 - ApolloDuoBookHingeHalfGap()),
          "Open feed is the full left half minus the hinge gutter");
    Check(open.feed.x + open.feed.width + 0.5 <= 1133.0 * 0.5,
          "Open feed stays left of the hinge mid");
    Check(open.detail.x + 0.5 >= 1133.0 * 0.5,
          "Open comments start after the hinge mid");
    Check(Near(ApolloDuoBookPaneGap(open), (double)ApolloDuoBookHingeGap),
          "Open book leaves a 40pt hinge gutter so panes do not bleed");
    Check(Near(open.detail.x + open.detail.width,
               1133.0 - (double)ApolloDuoBookDetailTrailingChrome),
          "Open comments stop before the trailing bezel chrome");
    Check(open.detail.x + open.detail.width + 0.5
              <= 1133.0 - (double)ApolloDuoBookDetailCornerGutter + 0.5,
          "Open comments leave at least the Subs-sized corner gutter");
    Check(!ApolloFeedSplitRectSpansMidX(open.feed, 1133.0 * 0.5),
          "Open feed does not span the hinge");
    Check(!ApolloFeedSplitRectSpansMidX(open.detail, 1133.0 * 0.5),
          "Open comments do not span the hinge");
    Check(open.feed.width + 0.5 >= (double)ApolloDuoBookFeedMinWidth,
          "Open feed stays at least 320pt");
    Check(open.detail.width + 0.5 >= (double)ApolloDuoBookFeedMinWidth,
          "Open detail stays at least 320pt");

    ApolloFeedSplitFrames sim = ApolloDuoBookFramesForMode(951.0, 430.0,
                                                           ApolloDuoModePhone);
    Check(sim.showsDetail, "951pt Phone-mode book still exposes a right pane");
    Check(sim.feed.x + 0.5 < 1.0,
          "951pt book feed uses the full half-pane; no rail column");
    Check(sim.feed.width + 0.5 >= (double)ApolloDuoBookFeedMinWidth,
          "951pt left feed stays usable");
    Check(sim.detail.width + 0.5 >= (double)ApolloDuoBookFeedMinWidth,
          "951pt right pane stays usable");
    Check(Near(ApolloDuoBookPaneGap(sim), (double)ApolloDuoBookHingeGap),
          "951pt book leaves a 40pt hinge gutter");
    Check(sim.detail.x + sim.detail.width + 0.5
              <= 951.0 - (double)ApolloDuoBookDetailCornerGutter + 0.5,
          "951pt right pane clears the trailing corner");
    Check(sim.feed.x + sim.feed.width + 0.5 <= 951.0 * 0.5,
          "951pt feed stays left of mid");
    Check(sim.detail.x + 0.5 >= 951.0 * 0.5,
          "951pt comments stay right of mid");

    ApolloFeedSplitFrames mid = ApolloDuoBookFramesForMode(744.0, 1133.0,
                                                           ApolloDuoModeClosed);
    Check(mid.showsDetail, "mid-open-capable frames still reserve the right pane");
    Check(mid.feed.x + mid.feed.width + 0.5 <= 744.0 * 0.5,
          "portrait-inner feed stays left of mid");
    Check(mid.detail.x + 0.5 >= 744.0 * 0.5,
          "portrait-inner comments stay right of mid");
    Check(Near(ApolloDuoBookPaneGap(mid), (double)ApolloDuoBookHingeGap),
          "portrait-inner book leaves a 40pt hinge gutter");

    ApolloFeedSplitFrames empty = ApolloDuoBookFramesMake(400.0, 800.0, 0.0, 0.0);
    Check(empty.showsDetail && empty.feed.width + 0.5 <= 200.0,
          "a too-narrow canvas still reports book halves for the math");

    ApolloDuoRailRect pane = ApolloDuoBookPaneContentFrame(open.feed.width, 744.0);
    Check(Near(pane.x, 0.0) && Near(pane.width, open.feed.width),
          "left-pane children fill the pane, not the full window");
    Check(!ApolloDuoBookPaneOriginClearsRail(open.feed.x),
          "book left pane starts at 0 — no reserved rail column");
    Check(!ApolloDuoBookPaneOriginClearsRail(0.0),
          "a full-bleed pane origin is the locked book geometry");

    printf("OK: %u checks\n", checks);
    return 0;
}
