#ifndef APOLLO_DUO_BOOK_LAYOUT_H
#define APOLLO_DUO_BOOK_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <string.h>

#include "ApolloDuoCompatibility.h"
#include "ApolloDuoRailLayout.h"
#include "ApolloFeedSplitLayout.h"

// Duo "book" two-pane gate + frames. C-only so host tests compile
// without UIKit.
//
// Product (Aaron): split is ON for
//   1. fully-open landscape (wide inner canvas), and
//   2. mid-open book (hinge partially open — angled, not shut).
// Split is OFF for closed portrait Duo and every regular iPhone.
//
// Window mode (ApolloDuoModeFromBounds) is still the chrome source:
//   Phone  — stock tab bar, never split
//   Closed — portrait-sized Duo window (cover / folded inner)
//   Open   — wide landscape inner window
// Hinge status is a *second* signal. UIKit's UIHinge.status is
// unknown / closed / partiallyOpen / fullyOpen. We never call
// reservedRegions (SIGSEGV on Duo). Layout does not use hinge
// *angle* — Apple's guidance is status + size, not radians.
//
// When the hinge API is missing (older SDK, non-Duo, worker without
// the class) status is Unknown. Unknown + Open still enables the
// split so a landscape Duo sim without UIHingeInteraction is
// reviewable. Closed hinge on an Open (wide) window also splits —
// Duo sim reports hinge Closed on a fully-open landscape canvas.
// Unknown + Closed *mode* (narrow portrait) stays single-pane (V1).
//
// Runtime tiling lives in ApolloDuoBook — not ApolloFeedSplit
// (`ApolloFeedSplitEnabled` stays NO). FeedSplit math is reused
// only for the column rects.

enum {
    ApolloDuoHingeUnknown = 0,
    ApolloDuoHingeClosed = 1,
    ApolloDuoHingePartiallyOpen = 2,
    ApolloDuoHingeFullyOpen = 3,
};

enum {
    ApolloDuoBookPosturePhone = 0,
    ApolloDuoBookPostureClosed = 1,
    ApolloDuoBookPostureMidOpenBook = 2,
    ApolloDuoBookPostureFullyOpen = 3,
};

// Right-pane chrome. V1 RailChromeRight stays 0 (Closed lists).
// Book only: pull the detail host off the trailing Duo bezel /
// rounded corner / glass pill, and off the hinge mid.
enum {
    ApolloDuoBookHingeGap = 40,             /* visible book spine at mid */
    ApolloDuoBookFeedMinWidth = 320,        /* do not starve the list */
    ApolloDuoBookDetailCornerGutter = 16,   /* bezel / rounded corner */
    ApolloDuoBookDetailTrailingChrome = 16, /* host frame vs window trailing */
    ApolloDuoBookDetailBottomChrome = 16,   /* jump FAB above the corner */
};

static inline double ApolloDuoBookHingeHalfGap(void) {
    return (double)ApolloDuoBookHingeGap * 0.5;
}

// 0 while an overlay (media / composer / reply sheet), a size
// transition, or a nested ApplyFrames is in flight. Writing from
// viewDidLayout then re-enters Sync/FillSoon (same hang class as
// the old rail/fill loop).
static inline int ApolloDuoBookShouldWriteFrames(int overlayPresented,
                                                 int sizeTransition,
                                                 int applyInFlight) {
    if (overlayPresented) return 0;
    if (sizeTransition) return 0;
    if (applyInFlight) return 0;
    return 1;
}

// Map a UIKit UIHinge.status NSInteger. Out-of-range values are
// Unknown so a future extra case cannot enable the split by accident.
static inline int ApolloDuoHingeStatusFromUIKit(int raw) {
    if (raw == ApolloDuoHingeClosed) return ApolloDuoHingeClosed;
    if (raw == ApolloDuoHingePartiallyOpen) return ApolloDuoHingePartiallyOpen;
    if (raw == ApolloDuoHingeFullyOpen) return ApolloDuoHingeFullyOpen;
    return ApolloDuoHingeUnknown;
}

// Window mode wins for fully-open. Duo sim reports UIHinge.status
// Closed on a wide Open canvas; that must still split. True Closed
// portrait stays single-pane unless the hinge is genuinely
// partiallyOpen (mid-open book).
//
// V1 chrome still uses ApolloDuoWideWindowThreshold (1000). Duo sim
// fully-open inner is ~951pt landscape, so FromBounds returns Phone.
// Book treats that canvas as FullyOpen when it is landscape, two
// columns wide, and duoHint is set (glass / hinge class / dual
// display / rail). Regular iPhone portrait never splits. Regular
// iPhone landscape without a Duo hint stays Phone.
static inline int ApolloDuoBookPostureFromState(int duoMode, int hingeStatus) {
    if (duoMode == ApolloDuoModePhone) {
        return ApolloDuoBookPosturePhone;
    }
    if (duoMode == ApolloDuoModeOpen) {
        if (hingeStatus == ApolloDuoHingePartiallyOpen) {
            return ApolloDuoBookPostureMidOpenBook;
        }
        return ApolloDuoBookPostureFullyOpen;
    }
    if (hingeStatus == ApolloDuoHingePartiallyOpen) {
        return ApolloDuoBookPostureMidOpenBook;
    }
    return ApolloDuoBookPostureClosed;
}

static inline int ApolloDuoBookPostureFromCanvas(int duoMode,
                                                 int hingeStatus,
                                                 double width,
                                                 double height,
                                                 int duoHint) {
    int landscape = ApolloDuoIsLandscapeSized(width, height);
    int twoColumn = width + 0.5 >= (double)ApolloFeedSplitMinRegularWidth;
    if (duoMode == ApolloDuoModeOpen) {
        if (hingeStatus == ApolloDuoHingePartiallyOpen) {
            return ApolloDuoBookPostureMidOpenBook;
        }
        return ApolloDuoBookPostureFullyOpen;
    }
    if (duoMode == ApolloDuoModeClosed) {
        if (hingeStatus == ApolloDuoHingePartiallyOpen) {
            return ApolloDuoBookPostureMidOpenBook;
        }
        return ApolloDuoBookPostureClosed;
    }
    if (landscape && twoColumn && duoHint) {
        if (hingeStatus == ApolloDuoHingePartiallyOpen) {
            return ApolloDuoBookPostureMidOpenBook;
        }
        return ApolloDuoBookPostureFullyOpen;
    }
    return ApolloDuoBookPosturePhone;
}

static inline int ApolloDuoBookPostureAllowsSplit(int posture) {
    return posture == ApolloDuoBookPostureMidOpenBook
        || posture == ApolloDuoBookPostureFullyOpen;
}

// Left pane is the feed/list only. Comments (except the Saved Posts
// list) and media viewers belong on the right host — pinning them
// into the feed frame is the empty-right-pane bug.
static inline int ApolloDuoBookLeftPaneAllowsClass(const char *name) {
    if (!name) return 0;
    if (strstr(name, "MediaViewer") != NULL
        || strstr(name, "MediaPage") != NULL
        || strstr(name, "GalleryViewController") != NULL
        || strstr(name, "ImageViewer") != NULL) {
        return 0;
    }
    if (strstr(name, "CommentsViewController") != NULL
        && strstr(name, "SavedPosts") == NULL) {
        return 0;
    }
    if (strstr(name, "PostsViewController") != NULL
        || strstr(name, "LitePostsViewController") != NULL
        || strstr(name, "SavedPostsCommentsViewController") != NULL
        || strstr(name, "PostsSearchResultsViewController") != NULL
        || strstr(name, "RedditList") != NULL) {
        return 1;
    }
    return 0;
}

// Two 320pt columns + gutter. A mid-open cover (phone-narrow) must
// not split even if the hinge reports partiallyOpen.
static inline int ApolloDuoBookSplitShouldEnable(int posture, double usableWidth) {
    if (!ApolloDuoBookPostureAllowsSplit(posture)) return 0;
    return usableWidth + 0.5 >= (double)ApolloFeedSplitMinRegularWidth;
}

static inline int ApolloDuoBookSplitShouldEnableForCanvas(int duoMode,
                                                          int hingeStatus,
                                                          double width,
                                                          double height,
                                                          int duoHint) {
    int posture = ApolloDuoBookPostureFromCanvas(duoMode, hingeStatus,
                                                 width, height, duoHint);
    return ApolloDuoBookSplitShouldEnable(posture, width);
}

static inline int ApolloDuoBookSplitShouldEnableForWindow(int duoMode,
                                                          int hingeStatus,
                                                          double width,
                                                          double height) {
    return ApolloDuoBookSplitShouldEnableForCanvas(duoMode, hingeStatus,
                                                   width, height, 0);
}

// Open rail is leading. Book extraRight is trailing bezel chrome
// only — it does not install a rail and does not change V1 Closed.
static inline double ApolloDuoBookExtraLeftForMode(int mode) {
    return ApolloDuoRailChromeLeftForMode(mode);
}

static inline double ApolloDuoBookExtraRightForMode(int mode) {
    (void)mode;
    return (double)ApolloDuoBookDetailTrailingChrome;
}

// Frame already clears the bezel. Do not stack another trailing
// safe-area inset (that letterboxed the comments column).
static inline double ApolloDuoBookDetailSafeLeft(void) {
    return 0.0;
}

static inline double ApolloDuoBookDetailSafeRight(void) {
    return 0.0;
}

static inline double ApolloDuoBookDetailSafeBottom(void) {
    return (double)ApolloDuoBookDetailBottomChrome;
}

// Jump FAB maxX / maxY inside the already-inset detail pane.
static inline double ApolloDuoBookJumpMaxX(double paneWidth) {
    double limit = paneWidth - (double)ApolloDuoBookDetailCornerGutter;
    return limit > 0.0 ? limit : 0.0;
}

static inline double ApolloDuoBookJumpMaxY(double paneHeight) {
    double limit = paneHeight - (double)ApolloDuoBookDetailBottomChrome;
    return limit > 0.0 ? limit : 0.0;
}

// Two book pages around mid, with a visible hinge gap. Each column
// uses its half minus half-gap (floor 320 when the canvas allows).
// Placeholder still owns the right pane.
static inline ApolloFeedSplitFrames ApolloDuoBookFramesMake(double containerWidth,
                                                            double containerHeight,
                                                            double extraLeft,
                                                            double extraRight) {
    ApolloFeedSplitFrames frames;
    frames.feed.x = 0.0;
    frames.feed.y = 0.0;
    frames.feed.width = 0.0;
    frames.feed.height = containerHeight > 0.0 ? containerHeight : 0.0;
    frames.detail.x = 0.0;
    frames.detail.y = 0.0;
    frames.detail.width = 0.0;
    frames.detail.height = containerHeight > 0.0 ? containerHeight : 0.0;
    frames.showsDetail = 0;
    if (containerWidth <= 0.0 || containerHeight <= 0.0) return frames;

    if (extraLeft < 0.0) extraLeft = 0.0;
    if (extraRight < 0.0) extraRight = 0.0;
    double start = extraLeft;
    double end = containerWidth - extraRight;
    if (end < start + 1.0) end = containerWidth;
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    double half = ApolloDuoBookHingeHalfGap();
    double feedEnd = mid - half;
    double detailStart = mid + half;
    if (feedEnd < start) feedEnd = start;
    if (detailStart > end) detailStart = end;

    frames.showsDetail = 1;
    frames.feed.x = start;
    frames.feed.width = feedEnd - start;
    if (frames.feed.width < 0.0) frames.feed.width = 0.0;
    frames.detail.x = detailStart;
    frames.detail.width = end - detailStart;
    if (frames.detail.width < 0.0) frames.detail.width = 0.0;
    return frames;
}

static inline double ApolloDuoBookPaneGap(ApolloFeedSplitFrames frames) {
    return frames.detail.x - (frames.feed.x + frames.feed.width);
}

static inline ApolloFeedSplitFrames ApolloDuoBookFramesForMode(double containerWidth,
                                                               double containerHeight,
                                                               int mode) {
    return ApolloDuoBookFramesMake(containerWidth,
                                   containerHeight,
                                   ApolloDuoBookExtraLeftForMode(mode),
                                   ApolloDuoBookExtraRightForMode(mode));
}

// Children of a pane whose *origin* already sits at/after the rail
// fill (0,0,paneW,paneH). A second +120 inset is the V1 crush.
static inline ApolloDuoRailRect ApolloDuoBookPaneContentFrame(double paneWidth,
                                                              double paneHeight) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = paneWidth > 0.0 ? paneWidth : 0.0;
    rect.height = paneHeight > 0.0 ? paneHeight : 0.0;
    return rect;
}

// 1 when the pane is already past the rail, so a child at x=0 is clear.
static inline int ApolloDuoBookPaneOriginClearsRail(double paneWindowX) {
    return paneWindowX + 0.5 >= ApolloDuoRailContentLeftInset();
}

#ifdef __cplusplus
}
#endif

#endif
