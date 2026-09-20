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
              == ApolloDuoBookPostureClosed,
          "closed hinge tears the split down even if the window is still wide");

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
          "Max landscape (not Duo-wide) never splits");
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
    Check(!ApolloDuoBookSplitShouldEnableForWindow(ApolloDuoModeOpen,
                                                   ApolloDuoHingeClosed,
                                                   1133.0, 744.0),
          "closed hinge wins over a leftover Open window");

    Check(Near(ApolloDuoBookExtraLeftForMode(ApolloDuoModeOpen),
               ApolloDuoRailContentLeftInset()),
          "Open book extraLeft is the leading rail content inset");
    Check(Near(ApolloDuoBookExtraLeftForMode(ApolloDuoModeClosed), 0.0),
          "Closed book extraLeft is 0 (no reserved rail column)");
    Check(Near(ApolloDuoBookExtraRightForMode(ApolloDuoModeOpen), 0.0),
          "book extraRight is 0 — comments own the trailing half");

    ApolloFeedSplitFrames open = ApolloDuoBookFramesForMode(1133.0, 744.0,
                                                            ApolloDuoModeOpen);
    Check(open.showsDetail, "Open book always exposes a right pane (placeholder or post)");
    Check(open.feed.x + 0.5 >= ApolloDuoRailContentLeftInset() - 0.5,
          "Open feed starts at or after the rail");
    Check(open.feed.x + open.feed.width + 0.5 <= 1133.0 * 0.5,
          "Open feed stays left of the hinge mid");
    Check(open.detail.x + 0.5 >= 1133.0 * 0.5,
          "Open comments start at or after the hinge mid");
    Check(Near(open.detail.x + open.detail.width, 1133.0),
          "Open comments fill to the trailing book edge");
    Check(!ApolloFeedSplitRectSpansMidX(open.feed, 1133.0 * 0.5),
          "Open feed does not span the hinge");
    Check(!ApolloFeedSplitRectSpansMidX(open.detail, 1133.0 * 0.5),
          "Open comments do not span the hinge");

    ApolloFeedSplitFrames mid = ApolloDuoBookFramesForMode(744.0, 1133.0,
                                                           ApolloDuoModeClosed);
    Check(mid.showsDetail, "mid-open-capable frames still reserve the right pane");
    Check(mid.feed.x + mid.feed.width + 0.5 <= 744.0 * 0.5,
          "portrait-inner feed stays left of mid");
    Check(mid.detail.x + 0.5 >= 744.0 * 0.5,
          "portrait-inner comments stay right of mid");

    ApolloFeedSplitFrames empty = ApolloDuoBookFramesMake(400.0, 800.0, 0.0, 0.0);
    Check(empty.showsDetail && empty.feed.width + 0.5 <= 200.0,
          "a too-narrow canvas still reports book halves for the math");

    ApolloDuoRailRect pane = ApolloDuoBookPaneContentFrame(open.feed.width, 744.0);
    Check(Near(pane.x, 0.0) && Near(pane.width, open.feed.width),
          "left-pane children fill the pane, not the full window");
    Check(ApolloDuoBookPaneOriginClearsRail(open.feed.x),
          "Open left-pane origin already clears the rail");
    Check(!ApolloDuoBookPaneOriginClearsRail(0.0),
          "a full-bleed pane origin still needs the V1 rail shift");

    printf("OK: %u checks\n", checks);
    return 0;
}
