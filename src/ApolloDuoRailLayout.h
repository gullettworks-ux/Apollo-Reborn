#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

#include "ApolloDuoCompatibility.h"

// One Duo chrome path. Open Duo (wide landscape UIWindow) is a
// reserved leading 112pt sidebar (content starts at 120); the bottom
// tab bar is hidden. Closed Duo (portrait-sized Duo window) is
// Phone-like chrome: stock bottom UITabBar, no Apollo side rail, no
// reserved or overlayed trailing column. Regular iPhone is Phone —
// stock tab bar, no rail. C-only so host tests compile without UIKit.
//
// Top is safe.top + 8 only. Open content inset is rail + 8pt
// (112+8=120) on the leading side.

enum {
    ApolloDuoRailWidth = 112,      /* Open reserved sidebar, 100–120pt */
    ApolloDuoRailWidthClosed = 72, /* Closed overlay only — not a reserved column */
    ApolloDuoRailClosedIndexWidth = 16, /* typical UITableViewIndex; sits beside the rail */
    ApolloDuoRailEdgeGutter = 0,   /* flush leading sidebar */
    ApolloDuoRailContentGutter = 8, /* content gap after the Open rail hairline */
    ApolloDuoRailStatusGap = 8,  /* safe.top padding; ignore trailing pill */
    ApolloDuoRailMinRegularWidth = 652,
    ApolloDuoRailWideSingleScreen = 800,
    ApolloDuoRailLetterboxGap = 40, /* phone-width column vs usable fill */
    /* Kept for host tests only — do NOT apply at runtime. The wide-row
       title+star cluster ran only on landscape cells ≥480 and dragged
       FAVORITES titles mid-pane. Portrait (stock RedditList) is the look. */
    ApolloDuoRailRowMaxContentWidth = 480,
    ApolloDuoRailRowStarGap = 28,
    /* Legacy fixed 38pt column — do NOT apply as the runtime star X.
       The column is contentView.maxX minus live trailing (margins /
       A–Z), computed after a force-layout pass. 8 is only a floor. */
    ApolloDuoRailRowStarTrailing = 38,
    ApolloDuoRailRowStarMinTrailing = 8,
    ApolloDuoRailSectionLineTrailing = 8,
    ApolloDuoRailRowTitleStarGap = 12,
    ApolloDuoRailRowStarRetryLimit = 3,
    ApolloDuoRailRowStarSearchFloor = 48,
    /* Custom Duo star (not the native accessory). Size is the glyph;
       hit slop is the button itself. Trailing is pinned to the live
       UITableViewIndex leading edge minus this gap — never
       contentView.trailing minus a fuzzy chrome/margin guess. */
    ApolloDuoRailRowStarButtonSize = 28,
    ApolloDuoRailRowStarButtonHit = 44,
    ApolloDuoRailRowStarIndexGap = 8,
    ApolloDuoCoverPillWidth = 80,   /* cover system pill; Compact only */
    ApolloDuoCoverPillBottom = 120, /* lift FABs above the cover gear */
    /* Subs nav chrome (title / Edit / floating +). Insets only the
       controls — never the list — so Open stays full-width past the
       rail and Closed stays uncrushed. Corner gutter keeps glyphs off
       Duo's inner rounded corners without guessing a hinge rect. */
    ApolloDuoSubsChromeCornerGutter = 20,
    ApolloDuoSubsChromeFABSize = 56,
    ApolloDuoSubsChromeFABMargin = 16,
    /* UITableView's default leading. RedditList headers paint at 18;
       shortcut ApolloSubtitleTableViewCell icons sit at safe-area + 16
       after the 80pt rail inset (window ≈96). Favorite titles key off
       this, not the header 18→98 column. */
    ApolloDuoRailRowStockLead = 16,
};

typedef struct {
    double x;
    double y;
    double width;
    double height;
} ApolloDuoRailRect;

static inline double ApolloDuoRailMax(double a, double b) {
    return a > b ? a : b;
}

static inline double ApolloDuoRailLeadingChrome(void) {
    return (double)ApolloDuoRailEdgeGutter;
}

static inline double ApolloDuoRailContentLeftInset(void) {
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailContentGutter;
}

static inline double ApolloDuoRailContentRightInset(void) {
    return 0.0;
}

static inline double ApolloDuoRailChromeLeftForMode(int mode) {
    return mode == ApolloDuoModeOpen ? ApolloDuoRailContentLeftInset() : 0.0;
}

// Closed overlays the rail — never reserve ~120pt trailing. That
// reservation crushed the portrait list by ~20–25% (Image 1).
static inline double ApolloDuoRailChromeRightForMode(int mode) {
    (void)mode;
    return 0.0;
}

static inline double ApolloDuoRailWidthForMode(int mode) {
    return mode == ApolloDuoModeClosed ? (double)ApolloDuoRailWidthClosed
                                       : (double)ApolloDuoRailWidth;
}

static inline double ApolloDuoRailWidthOnSide(int leading) {
    return leading ? (double)ApolloDuoRailWidth : (double)ApolloDuoRailWidthClosed;
}

// Usable width after reserved chrome only. Open subtracts the leading
// 120pt column. Closed is full-bleed (overlay rail).
static inline double ApolloDuoRailContentFillWidthForMode(double containerWidth,
                                                         int mode) {
    if (containerWidth <= 0.0) return 0.0;
    double fill = containerWidth
        - ApolloDuoRailChromeLeftForMode(mode)
        - ApolloDuoRailChromeRightForMode(mode);
    return fill > 0.0 ? fill : 0.0;
}

// Usable width right of the leading rail. Stock nav letterboxes to a
// phone column on the wide inner canvas; fill targets this width.
static inline double ApolloDuoRailContentFillWidth(double containerWidth) {
    return ApolloDuoRailContentFillWidthForMode(containerWidth, ApolloDuoModeOpen);
}

// Portrait Closed list is crushed when a reserved column eats ~20%+.
// Overlay + full-bleed content must fail this (acceptance test).
static inline int ApolloDuoRailClosedContentIsCrushed(double contentWidth,
                                                     double containerWidth) {
    if (containerWidth <= 0.0) return 0;
    return contentWidth + containerWidth * 0.20 < containerWidth;
}

static inline int ApolloDuoRailContentIsLetterboxed(double contentWidth,
                                                    double containerWidth) {
    return contentWidth + (double)ApolloDuoRailLetterboxGap
        < ApolloDuoRailContentFillWidth(containerWidth);
}

// Table/content frame that starts after the leading rail. Headers in a
// full-bleed table ignore additionalSafeAreaInsets and draw under Subs.
static inline ApolloDuoRailRect ApolloDuoRailContentFrameInBoundsForMode(double boundsWidth,
                                                                        double boundsHeight,
                                                                        int mode) {
    ApolloDuoRailRect rect;
    rect.x = ApolloDuoRailChromeLeftForMode(mode);
    rect.y = 0.0;
    rect.width = ApolloDuoRailContentFillWidthForMode(boundsWidth, mode);
    rect.height = boundsHeight > 0.0 ? boundsHeight : 0.0;
    if (rect.width < 0.0) rect.width = 0.0;
    return rect;
}

static inline ApolloDuoRailRect ApolloDuoRailContentFrameInBounds(double boundsWidth,
                                                                 double boundsHeight) {
    return ApolloDuoRailContentFrameInBoundsForMode(boundsWidth, boundsHeight,
                                                    ApolloDuoModeOpen);
}

static inline int ApolloDuoRailContentNeedsLeadingClearance(double contentX,
                                                           double contentWidth,
                                                           double containerWidth) {
    if (containerWidth <= 0.0) return 0;
    if (contentX + 0.5 < ApolloDuoRailContentLeftInset()) return 1;
    return ApolloDuoRailContentIsLetterboxed(contentWidth, containerWidth);
}

// Extra x to add to a *title* that is still under the rail. 0 when the
// title's window minX is already at/after the content inset. Positive
// only — 92ea260 used this as the whole policy and left Image 1
// (mid-pane have≈400) untouched. Runtime lead-align uses
// ApolloDuoRailRowLeadDelta (signed) instead.
static inline double ApolloDuoRailRowTitleBump(double titleWindowX) {
    if (titleWindowX + 0.5 >= ApolloDuoRailContentLeftInset()) return 0.0;
    return ApolloDuoRailContentLeftInset() - titleWindowX;
}

// Unused at runtime (wide-row cluster is off). Kept so host tests still
// lock the old 480pt math. Do not apply this as a leading or trailing
// margin — that is the mid-pane FAVORITES indent on landscape Duo.
static inline double ApolloDuoRailRowTrailingExtra(double cellWidth) {
    if (cellWidth <= (double)ApolloDuoRailRowMaxContentWidth) return 0.0;
    return cellWidth - (double)ApolloDuoRailRowMaxContentWidth;
}

// Leading rail is away from Duo's trailing status pill. Only safe.top
// plus a modest pad — do not honor pillMaxY.
static inline double ApolloDuoRailTopInset(double safeTop, double pillMaxY) {
    (void)pillMaxY;
    if (safeTop < 0.0) safeTop = 0.0;
    return safeTop + (double)ApolloDuoRailStatusGap;
}

// Open: stock A–Z on the list trailing edge (0 extra). Closed: pin
// the index immediately left of the overlay rail.
static inline double ApolloDuoRailSectionIndexTrailingForMode(int mode) {
    return mode == ApolloDuoModeClosed ? (double)ApolloDuoRailWidthClosed : 0.0;
}

static inline double ApolloDuoRailSectionIndexTrailing(void) {
    return ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoModeOpen);
}

// Leftover Closed overlay math (rail + A–Z). Not applied to stars or
// section lines — Closed has no side rail. Host tests lock the number
// so we cannot silently reuse it as a trailing inset.
static inline double ApolloDuoRailClosedOverlayClearance(void) {
    return (double)ApolloDuoRailWidthClosed + (double)ApolloDuoRailClosedIndexWidth;
}

// Leftover helper: max(margins.right, A–Z strip, floor). Runtime
// stars pin to the live index leading edge
// (ApolloDuoRailRowStarTrailingFromGuide), not this mix. Host tests
// still lock it so a margins-only path cannot sneak back.
static inline double ApolloDuoRailRowLiveStarTrailing(double marginRight,
                                                      double indexStrip,
                                                      double minTrailing) {
    if (marginRight < 0.0) marginRight = 0.0;
    if (indexStrip < 0.0) indexStrip = 0.0;
    if (minTrailing < 0.0) minTrailing = 0.0;
    double trailing = marginRight;
    if (indexStrip > trailing) trailing = indexStrip;
    if (minTrailing > trailing) trailing = minTrailing;
    return trailing;
}

// Live A–Z strip from cell vs contentView frames. A real index width
// (~16pt) is the trailing edge — do not zero it.
static inline double ApolloDuoRailRowIndexStrip(double cellWidth, double contentMaxX) {
    double strip = cellWidth - contentMaxX;
    return strip > 0.0 ? strip : 0.0;
}

// After UITableView layoutSubviews: one coalesced next-turn walk of
// every visible cell. No layoutIfNeeded (scroll/layout hang class).
static inline int ApolloDuoRailRowShouldScheduleAfterLayoutPass(int alreadyScheduled) {
    return alreadyScheduled ? 0 : 1;
}

// Open and Closed share one contentView-relative formula. Phone is 0
// so callers can skip. The leftover 38pt constant is not the column.
static inline double ApolloDuoRailRowStarTrailingForMode(int mode) {
    if (mode != ApolloDuoModeOpen && mode != ApolloDuoModeClosed) return 0.0;
    return (double)ApolloDuoRailRowStarMinTrailing;
}

// Far-right star column. Same cell-local maxX on every starred row
// (Favorites and A–Z). Does not key off title width and does not
// reserve the removed Closed overlay rail.
static inline double ApolloDuoRailRowStarColumnMaxX(double cellWidth,
                                                    double trailing) {
    if (cellWidth <= 0.0) return 0.0;
    if (trailing < 0.0) trailing = 0.0;
    double maxX = cellWidth - trailing;
    return maxX > 0.0 ? maxX : 0.0;
}

static inline double ApolloDuoRailRowStarColumnMinX(double cellWidth,
                                                    double starWidth,
                                                    double trailing) {
    if (starWidth < 0.0) starWidth = 0.0;
    double minX = ApolloDuoRailRowStarColumnMaxX(cellWidth, trailing) - starWidth;
    return minX > 0.0 ? minX : 0.0;
}

static inline int ApolloDuoRailRowShouldNudgeStar(double haveMaxX, double wantMaxX) {
    double gap = wantMaxX - haveMaxX;
    if (gap < 0.0) gap = -gap;
    return gap > 0.5;
}

// Star maxX immediately left of the live A–Z edge when that edge is
// in/at this contentView. Otherwise content.maxX minus liveTrailing.
static inline double ApolloDuoRailRowStarMaxXLeftOfIndex(double contentWidth,
                                                         double indexMinXInContent,
                                                         double liveTrailing) {
    if (indexMinXInContent > 0.5 && indexMinXInContent <= contentWidth + 0.5) {
        return indexMinXInContent;
    }
    return ApolloDuoRailRowStarColumnMaxX(contentWidth, liveTrailing);
}

static inline int ApolloDuoRailRowStarIsOutlier(double haveMaxX, double wantMaxX) {
    return ApolloDuoRailRowShouldNudgeStar(haveMaxX, wantMaxX);
}

// Width-only clamp so a stretchy title cannot run under the star
// column. Origin stays put (left-aligned).
static inline double ApolloDuoRailRowTitleMaxWidth(double titleMinX,
                                                   double starMinX,
                                                   double gap) {
    if (gap < 0.0) gap = 0.0;
    double width = starMinX - gap - titleMinX;
    return width > 0.0 ? width : 0.0;
}

static inline int ApolloDuoRailRowShouldShrinkTitle(double haveWidth, double wantWidth) {
    return haveWidth > wantWidth + 0.5;
}

// Section divider (FAVORITES / MODERATOR / A) ends at the content
// trailing gutter — full-width of the usable band, not a readable
// column and not 88pt inland of a removed overlay rail.
static inline double ApolloDuoRailSectionLineMaxX(double headerWidth,
                                                  double trailing) {
    return ApolloDuoRailRowStarColumnMaxX(headerWidth, trailing);
}

static inline int ApolloDuoRailRowPolishShouldApply(int mode) {
    return mode == ApolloDuoModeOpen || mode == ApolloDuoModeClosed;
}

// Duo owns a custom star's appearance/position. Phone keeps Apollo's
// native accessory. Reinstall on every configure / willDisplay /
// open-close — one-shot claim left reused cells with a prior
// subreddit binding and a stale trailing constant.
static inline int ApolloDuoRailRowShouldInstallCustomStar(int mode) {
    return ApolloDuoRailRowPolishShouldApply(mode);
}

static inline int ApolloDuoRailRowShouldReinstallStar(int alreadyInstalled) {
    (void)alreadyInstalled;
    return 1;
}

static inline int ApolloDuoRailRowShouldClaimStarButton(int alreadyClaimed) {
    return ApolloDuoRailRowShouldReinstallStar(alreadyClaimed);
}

static inline int ApolloDuoRailRowShouldClearStarOnReuse(int hasCustomStar) {
    (void)hasCustomStar;
    return 1;
}

// Prior cell's name / missing superview / missing name = stale.
// Never keep a reused row's frame or Favorite binding.
static inline int ApolloDuoRailRowStarBindingIsStale(int hasName,
                                                     int namesMatch,
                                                     int hasSuperview) {
    if (!hasName || !namesMatch || !hasSuperview) return 1;
    return 0;
}

static inline int ApolloDuoRailRowStarShouldShowFilled(int inFavoritesList,
                                                      int inFavoritesSection) {
    return (inFavoritesList || inFavoritesSection) ? 1 : 0;
}

static inline double ApolloDuoRailRowStarButtonTrailing(void) {
    return (double)ApolloDuoRailRowStarIndexGap;
}

// Leftover: view minX → trailing inset. Runtime stars no longer use
// this as the column (it returned 0 when the index sat at/past
// content.maxX). Host tests keep the leading-half filter.
static inline double ApolloDuoRailRowTrailingInsetFromMinX(double contentWidth,
                                                           double minXInContent) {
    if (contentWidth <= 0.0) return 0.0;
    if (minXInContent <= contentWidth * 0.5) return 0.0;
    if (minXInContent >= contentWidth) return 0.0;
    return contentWidth - minXInContent;
}

// Leftover max(index, chrome, floor). Do not use for custom stars —
// that path collapsed to the 8pt floor when chrome was missed.
static inline double ApolloDuoRailRowStarConstraintTrailing(double indexInset,
                                                            double chromeInset,
                                                            double minTrailing) {
    if (indexInset < 0.0) indexInset = 0.0;
    if (chromeInset < 0.0) chromeInset = 0.0;
    if (minTrailing < 0.0) minTrailing = 0.0;
    double trailing = indexInset;
    if (chromeInset > trailing) trailing = chromeInset;
    if (minTrailing > trailing) trailing = minTrailing;
    return trailing;
}

// Never drop the A–Z inset because contentView "looks" inset.
// contentAlreadyInset > 0.5 → 0 was the reuse/mode-change bug:
// the flag was true while the index still overlapped the band.
static inline double ApolloDuoRailRowIndexConstraintInset(double indexInsetInContent,
                                                          double contentAlreadyInset) {
    (void)contentAlreadyInset;
    return indexInsetInContent > 0.0 ? indexInsetInContent : 0.0;
}

// button.maxX = guideLeading - gap, expressed as a
// contentView.trailingAnchor constant. When the guide sits at or
// past content.maxX (false "already inset" frames), still reserve
// guideWidth + gap so trailing cannot collapse to the 8pt floor.
static inline double ApolloDuoRailRowStarTrailingFromGuide(double contentWidth,
                                                           double guideLeadingInContent,
                                                           double guideWidth,
                                                           double gap) {
    if (gap < 0.0) gap = 0.0;
    if (guideWidth < 0.0) guideWidth = 0.0;
    double fromWidth = guideWidth + gap;
    if (contentWidth <= 0.0) return fromWidth;
    if (guideLeadingInContent <= 0.5) return fromWidth;
    double fromLead = contentWidth - guideLeadingInContent + gap;
    return fromLead > fromWidth ? fromLead : fromWidth;
}

// Leftmost live guide: A–Z leading, or a trailing-side rail leading.
static inline double ApolloDuoRailRowStarClearLeading(double indexLeading,
                                                      double railLeading) {
    int haveIndex = indexLeading > 0.5;
    int haveRail = railLeading > 0.5;
    if (haveIndex && haveRail) {
        return indexLeading < railLeading ? indexLeading : railLeading;
    }
    if (haveIndex) return indexLeading;
    if (haveRail) return railLeading;
    return 0.0;
}

// First-paint reserve when the index is not laid out yet. Closed is
// A–Z + gap only (stock tabs). Open adds a trailing-rail clear only
// when the caller measured a trailing-side ApolloDuoRailView.
static inline double ApolloDuoRailRowStarModeReserve(int mode,
                                                     double indexWidth,
                                                     double gap,
                                                     double trailingRailClear) {
    if (indexWidth < 0.0) indexWidth = 0.0;
    if (gap < 0.0) gap = 0.0;
    if (trailingRailClear < 0.0) trailingRailClear = 0.0;
    if (mode != ApolloDuoModeOpen) trailingRailClear = 0.0;
    return indexWidth + trailingRailClear + gap;
}

// Smoking-gun detector: a live index strip must not park on the floor.
static inline int ApolloDuoRailRowStarTrailingCollapsesToFloor(double trailing,
                                                              double floorTrailing,
                                                              double indexWidth) {
    if (indexWidth <= 0.5) return 0;
    return trailing <= floorTrailing + 0.5;
}

static inline int ApolloDuoRailRowShouldUpdateStarTrailing(double haveConstant,
                                                           double wantConstant) {
    double gap = haveConstant - wantConstant;
    if (gap < 0.0) gap = -gap;
    return gap > 0.5;
}

// Full table+cell layoutIfNeeded only on appear / mode / rotation —
// never on every scroll tick (that is the 25f8a7b hang class).
static inline int ApolloDuoRailRowShouldForceLayout(int fromScroll) {
    return fromScroll ? 0 : 1;
}

static inline int ApolloDuoRailRowShouldBeginLayoutPass(int alreadyInPass) {
    return alreadyInPass ? 0 : 1;
}

static inline int ApolloDuoRailRowShouldScheduleStarRetry(int attempt,
                                                          int hasStar,
                                                          int needsNudge) {
    if (attempt >= ApolloDuoRailRowStarRetryLimit) return 0;
    if (!hasStar) return 1;
    return needsNudge ? 1 : 0;
}

// Open window already landscape-wide, but contentView / table still
// Closed or phone-column sized. Parking now is the first-open bug:
// stars lock to the narrow maxX, then stillOff=NO so we stop.
static inline int ApolloDuoRailRowContentLooksStaleForOpen(double contentWidth,
                                                           double windowWidth,
                                                           double windowHeight) {
    if (contentWidth <= 0.0 || windowWidth <= 0.0) return 0;
    if (ApolloDuoModeFromBounds(1, windowWidth, windowHeight) != ApolloDuoModeOpen
        && ApolloDuoModeFromBounds(0, windowWidth, windowHeight) != ApolloDuoModeOpen) {
        return 0;
    }
    double openFill = ApolloDuoRailContentFillWidthForMode(windowWidth, ApolloDuoModeOpen);
    return contentWidth + (double)ApolloDuoRailLetterboxGap < openFill;
}

// contentView still a readable/Closed strip inside an already-wide cell.
static inline int ApolloDuoRailRowContentViewLooksLetterboxed(double contentWidth,
                                                              double cellWidth) {
    if (contentWidth <= 0.0 || cellWidth <= 0.0) return 0;
    return contentWidth + (double)ApolloDuoRailLetterboxGap < cellWidth;
}

// Stored mode is Open but the window is still 0×0 or Closed-sized.
static inline int ApolloDuoRailRowOpenBoundsUnsettled(int mode,
                                                      double windowWidth,
                                                      double windowHeight) {
    if (mode != ApolloDuoModeOpen) return 0;
    if (windowWidth <= 0.0 || windowHeight <= 0.0) return 1;
    return ApolloDuoModeFromBounds(1, windowWidth, windowHeight) != ApolloDuoModeOpen
        && ApolloDuoModeFromBounds(0, windowWidth, windowHeight) != ApolloDuoModeOpen;
}

// Defer the contentView re-anchor until Open fill width is live.
static inline int ApolloDuoRailRowShouldDeferOpenReanchor(int mode,
                                                          double contentWidth,
                                                          double tableWidth,
                                                          double windowWidth,
                                                          double windowHeight) {
    if (ApolloDuoRailRowOpenBoundsUnsettled(mode, windowWidth, windowHeight)) {
        return 1;
    }
    if (ApolloDuoRailRowContentLooksStaleForOpen(contentWidth, windowWidth, windowHeight)) {
        return 1;
    }
    if (ApolloDuoRailRowContentLooksStaleForOpen(tableWidth, windowWidth, windowHeight)) {
        return 1;
    }
    return 0;
}

// Do not nudge onto a stale Closed/narrow maxX. After the retry
// budget, accept the current width so Closed/portrait can settle.
static inline int ApolloDuoRailRowShouldAcceptCurrentContent(int attempt,
                                                             int contentLooksStale) {
    if (!contentLooksStale) return 1;
    return attempt >= ApolloDuoRailRowStarRetryLimit ? 1 : 0;
}

static inline int ApolloDuoRailRowShouldNudgeStarIfReady(double haveMaxX,
                                                         double wantMaxX,
                                                         int contentLooksStale) {
    if (contentLooksStale) return 0;
    return ApolloDuoRailRowShouldNudgeStar(haveMaxX, wantMaxX);
}

// Retry when the star is missing, still off, or parked on stale
// Closed geometry (the old 3-arg helper treats that as "on target").
static inline int ApolloDuoRailRowShouldScheduleStarRetryForGeometry(int attempt,
                                                                     int hasStar,
                                                                     int needsNudge,
                                                                     int contentLooksStale) {
    if (attempt >= ApolloDuoRailRowStarRetryLimit) return 0;
    if (contentLooksStale) return 1;
    return ApolloDuoRailRowShouldScheduleStarRetry(attempt, hasStar, needsNudge);
}

// One deferred force-layout after appear/mode (Open bounds often
// land on the next pass). Keep retrying only while still stale.
// alreadyScheduled / attempt cap keeps this hang-safe.
static inline int ApolloDuoRailRowShouldScheduleDeferredForce(int alreadyScheduled,
                                                              int attempt,
                                                              int fromForceLayout,
                                                              int shouldDefer) {
    if (alreadyScheduled) return 0;
    if (attempt >= ApolloDuoRailRowStarRetryLimit) return 0;
    if (shouldDefer) return 1;
    return fromForceLayout && attempt == 0 ? 1 : 0;
}

// Open↔Closed (or any mode change) must drop a cached Closed column
// so leftover margins / parked X cannot survive the next pass.
static inline int ApolloDuoRailRowShouldClearCachedColumn(int hasLastMode,
                                                          int lastMode,
                                                          int newMode) {
    if (!hasLastMode) return 0;
    return lastMode != newMode;
}

static inline int ApolloDuoRailRowShouldRevisitMargins(double lastContentWidth,
                                                       double contentWidth,
                                                       int lastMode,
                                                       int newMode) {
    if (lastMode != newMode) return 1;
    return contentWidth > lastContentWidth + (double)ApolloDuoRailLetterboxGap;
}

// Walk-search floor so a mid-pane first-paint star is still found.
static inline double ApolloDuoRailRowStarSearchMinX(double contentWidth) {
    if (contentWidth <= 0.0) return 0.0;
    double frac = contentWidth * 0.15;
    double floorX = (double)ApolloDuoRailRowStarSearchFloor;
    return frac < floorX ? frac : floorX;
}

// Readable-centered leftover: a ~124pt leading on a wide cell. Stock
// portrait is safe+16. Reset these on reuse so landscape mid-pane
// margins cannot survive into Closed / a later Open pass.
static inline int ApolloDuoRailRowMarginsLookCentered(double contentWidth,
                                                      double marginLeft,
                                                      double stockLead) {
    if (contentWidth <= 0.0) return 0;
    if (marginLeft < stockLead) marginLeft = stockLead;
    return (marginLeft - stockLead) > 24.0;
}

static inline int ApolloDuoRailRowMarginsNeedReset(double contentWidth,
                                                   double cellWidth,
                                                   double marginLeft,
                                                   double stockLead) {
    if (ApolloDuoRailRowMarginsLookCentered(contentWidth, marginLeft, stockLead)) {
        return 1;
    }
    return ApolloDuoRailRowContentViewLooksLetterboxed(contentWidth, cellWidth);
}

// Hit-proxy origin in contentView: center on the native star, do not
// key off the cell's (possibly stale) bounds.
static inline double ApolloDuoRailRowProxyMinX(double starMidX,
                                               double proxyWidth,
                                               double contentWidth) {
    if (proxyWidth < 0.0) proxyWidth = 0.0;
    double minX = starMidX - proxyWidth * 0.5;
    double maxMinX = contentWidth - proxyWidth;
    if (maxMinX < 0.0) maxMinX = 0.0;
    if (minX < 0.0) minX = 0.0;
    if (minX > maxMinX) minX = maxMinX;
    return minX;
}

// Closed star helpers now use the shared far-right column. The
// overlay-rail reservation (ClosedOverlayClearance) is leftover
// math — do not apply it at runtime.
static inline double ApolloDuoRailRowStarMaxXInContent(double contentWidth,
                                                       double liveTrailing) {
    return ApolloDuoRailRowStarColumnMaxX(contentWidth, liveTrailing);
}

static inline double ApolloDuoRailClosedStarMaxX(double cellWidth) {
    return ApolloDuoRailRowStarMaxXInContent(cellWidth,
                                             (double)ApolloDuoRailRowStarMinTrailing);
}

static inline double ApolloDuoRailClosedStarMinX(double cellWidth, double starWidth) {
    return ApolloDuoRailRowStarColumnMinX(cellWidth, starWidth,
                                          (double)ApolloDuoRailRowStarMinTrailing);
}

static inline int ApolloDuoRailClosedShouldNudgeStar(double starMaxX, double wantMaxX) {
    return ApolloDuoRailRowShouldNudgeStar(starMaxX, wantMaxX);
}

// Cover / Compact + dual screens: extra trailing/bottom so FABs clear
// Duo's system pill. Regular (open inner) never uses this — the Apollo
// rail is the chrome there. Ordinary single-screen Compact is 0.
static inline int ApolloDuoCoverChromeShouldApply(int regularSizeClass,
                                                 int dualDisplay) {
    return !regularSizeClass && dualDisplay;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBoundsOnSide(double boundsWidth,
                                                                double boundsHeight,
                                                                double safeTop,
                                                                double safeBottom,
                                                                double pillMaxY,
                                                                int leading) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = 0.0;
    rect.height = 0.0;
    if (boundsWidth <= 0.0 || boundsHeight <= 0.0) {
        return rect;
    }
    if (safeBottom < 0.0) safeBottom = 0.0;
    double top = ApolloDuoRailTopInset(safeTop, pillMaxY);
    rect.width = ApolloDuoRailWidthOnSide(leading);
    rect.height = boundsHeight - top - safeBottom;
    if (rect.height < 0.0) rect.height = 0.0;
    rect.x = leading ? ApolloDuoRailLeadingChrome()
                     : boundsWidth - rect.width;
    if (rect.x < 0.0) rect.x = 0.0;
    rect.y = top;
    return rect;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBounds(double boundsWidth,
                                                          double boundsHeight,
                                                          double safeTop,
                                                          double safeBottom,
                                                          double pillMaxY) {
    return ApolloDuoRailFrameInBoundsOnSide(boundsWidth, boundsHeight,
                                            safeTop, safeBottom, pillMaxY, 1);
}

// Modern RedditList headers are painted at a hardcoded stockTitleX
// (18pt). When the header still sits under the leading rail in window
// space, shift the title by the overlap so "FAVORITES" is not clipped
// to "ES". A header that already starts at x >= ContentLeftInset is left alone.
static inline double ApolloDuoRailHeaderTitleMinX(double headerWindowX,
                                                  double stockTitleX) {
    if (stockTitleX < 0.0) stockTitleX = 0.0;
    double overlap = ApolloDuoRailContentLeftInset() - headerWindowX;
    if (overlap < 0.0) overlap = 0.0;
    return stockTitleX + overlap;
}

// Target title minX *inside a full-bleed RedditList cell* — same number
// StyleHeaderView uses for FAVORITES / MODERATOR / A. stockTitleX is
// Apollo's 18pt leading. A cell that already starts past the rail
// (window x >= 80) keeps stock 18 so we do not stack another inset.
// Runtime favorite-row align uses ApolloDuoRailShortcutLeadMinX (16)
// instead — 2eba156 keyed titles to this 18→98 header column, then
// stacked a stale remainder on top and parked them at ~178.
static inline double ApolloDuoRailRowTitleMinX(double cellWindowX,
                                               double stockTitleX) {
    return ApolloDuoRailHeaderTitleMinX(cellWindowX, stockTitleX);
}

// Fallback wantX for a favorite / A–Z title: shortcut-row leading
// (safe-area + UITableView's 16pt), not the header's 18pt. Full-bleed
// cell → 96. A cell already past the rail keeps stock 16.
static inline double ApolloDuoRailShortcutLeadMinX(double cellWindowX) {
    return ApolloDuoRailHeaderTitleMinX(cellWindowX,
                                        (double)ApolloDuoRailRowStockLead);
}

// Favorite rows have no icon. Portrait organization lines their
// titles up with Home / Popular *text*, not the shortcut icon.
// 4a76cd3 preferred the icon (96) and then Auto Layout snapped the
// stack back, so the painted column stayed at ~178. Runtime wantX
// is a live textLabel; fallback is last.
static inline double ApolloDuoRailFavoriteTitleWantX(double iconMinX,
                                                     double textMinX,
                                                     double fallback) {
    if (textMinX > 0.5) return textMinX;
    if (iconMinX > 0.5) return iconMinX;
    return fallback;
}

// Horizontal constraint disable is one-shot. Re-toggling every
// layoutSubviews is the 25f8a7b hang. 0 when already claimed.
static inline int ApolloDuoRailRowShouldClaimLeading(int alreadyClaimed) {
    return alreadyClaimed ? 0 : 1;
}

// After a real stack origin change, convertRect can still report the
// pre-move title minX. 2eba156 applied that stale LeadDelta again
// (stack +80, then title.frame +80) and parked names at ~178 while
// headers stayed at 98. Remainder is only for a no-op stack write
// (full-bleed stack at x=0 with a mid-stack title).
static inline int ApolloDuoRailRowShouldApplyTitleRemainder(int stackMoved,
                                                            double remain) {
    if (stackMoved) return 0;
    if (remain < 0.0) remain = -remain;
    return remain > 0.5;
}

// Visual text minX inside a label. Center/right alignment on a stretchy
// wide label is how "Apple" can sit mid-pane while label.minX is still 18.
enum {
    ApolloDuoRailTextAlignLeft = 0,
    ApolloDuoRailTextAlignCenter = 1,
    ApolloDuoRailTextAlignRight = 2,
};

static inline double ApolloDuoRailLabelTextMinX(double labelMinX,
                                                double labelWidth,
                                                double textWidth,
                                                int align) {
    if (textWidth < 0.0) textWidth = 0.0;
    if (labelWidth < textWidth) labelWidth = textWidth;
    if (align == ApolloDuoRailTextAlignCenter) {
        return labelMinX + (labelWidth - textWidth) * 0.5;
    }
    if (align == ApolloDuoRailTextAlignRight) {
        return labelMinX + (labelWidth - textWidth);
    }
    return labelMinX;
}

// Signed delta that puts visual text at wantX. Positive = still under the
// rail (push right, capped at ContentLeftInset so we cannot stack a
// second 80pt). Negative = mid-pane / readable-centered (pull left).
// 92ea260 only applied the positive arm, so Image 1 (have≈400, want=98)
// was left untouched.
static inline double ApolloDuoRailRowLeadDelta(double haveTextMinX,
                                               double wantX) {
    double delta = wantX - haveTextMinX;
    double maxRight = ApolloDuoRailContentLeftInset();
    if (delta > maxRight) delta = maxRight;
    return delta;
}

// Legacy after-text cluster (title + gap). Host tests lock this so we
// cannot silently revive the landscape path that dragged FAVORITES
// names mid-pane. Runtime stars use ApolloDuoRailRowStarColumnMaxX.
static inline double ApolloDuoRailRowStarMinX(double titleMinX,
                                              double textWidth,
                                              double gap) {
    if (textWidth < 0.0) textWidth = 0.0;
    if (gap < 0.0) gap = 0.0;
    return titleMinX + textWidth + gap;
}

// Extra leading a centered readable column adds on a wide cell. Portrait
// phone width (≤ readableMax) is 0 — titles stay stock. Landscape Duo
// (~900pt) is tens to hundreds of points, which is the mid-pane gap.
// Runtime must NOT keep that extra: landscape uses the same stock
// leading as portrait, plus rail safe-area only.
static inline double ApolloDuoRailReadableLeading(double cellWidth,
                                                  double readableMax) {
    if (readableMax <= 0.0 || cellWidth <= readableMax) return 0.0;
    return (cellWidth - readableMax) * 0.5;
}

// Portrait organization: content leading is safe-area + stock 16.
// Full-bleed cell under the rail → 80+16=96. A contentView already
// inset by the table's safe-area has safeLeft=0 → 16. Never add the
// readable-column half-gap on top of that.
static inline double ApolloDuoRailRowStockMarginLeft(double safeLeft) {
    if (safeLeft < 0.0) safeLeft = 0.0;
    return safeLeft + (double)ApolloDuoRailRowStockLead;
}

// Same leading line as Home / Popular (a few points). A second
// indented column (Image 1 ~178, or 18+readable 124) fails this.
static inline int ApolloDuoRailRowIsPortraitOrganized(double titleMinX,
                                                      double shortcutLead) {
    double gap = titleMinX - shortcutLead;
    if (gap < 0.0) gap = -gap;
    return gap <= 4.0;
}

static inline double ApolloDuoRailRowWastedLeading(double titleMinX,
                                                   double shortcutLead) {
    double gap = titleMinX - shortcutLead;
    return gap > 0.0 ? gap : 0.0;
}

// Frame-only stack nudge. 0 when already on the shortcut lead so
// layoutSubviews is a no-op. Constraint / margin writes are not a
// tool here — they re-entered layout on 25f8a7b and hung the sim.
static inline int ApolloDuoRailRowShouldNudgeStack(double titleMinX,
                                                   double shortcutLead) {
    return !ApolloDuoRailRowIsPortraitOrganized(titleMinX, shortcutLead);
}

// Rail only for Open (wide landscape). Closed portrait Duo and
// regular iPhone keep the stock bottom UITabBar — Aaron does not
// want Posts/Subs/Home/… moved to a side rail in portrait.
static inline int ApolloDuoRailShouldShow(int regularSizeClass,
                                          int dualDisplay,
                                          double usableWidth,
                                          double usableHeight) {
    (void)regularSizeClass;
    return ApolloDuoModeFromBounds(dualDisplay, usableWidth, usableHeight)
        == ApolloDuoModeOpen;
}

// Subs nav chrome (centered title, Edit, floating +) on Duo only.
// Regular iPhone stays stock Apollo. Does not show or hide the rail.
static inline int ApolloDuoSubsChromeShouldApply(int mode) {
    return mode == ApolloDuoModeOpen || mode == ApolloDuoModeClosed;
}

// Inline (not large) title so Liquid Glass / UIKit can center it.
// Closed Compact keeps Apollo's stock large title.
static inline int ApolloDuoSubsChromeShouldForceInlineTitle(int mode,
                                                            int regularWidth) {
    if (!ApolloDuoSubsChromeShouldApply(mode)) return 0;
    if (mode == ApolloDuoModeOpen) return 1;
    return regularWidth ? 1 : 0;
}

// Title leading edge in bar space. Open: at least the rail content
// inset so "Subreddits" cannot sit under Posts/Subs. Closed: chrome
// only (no rail).
static inline double ApolloDuoSubsChromeTitleLeading(int mode,
                                                     double chromeLeft) {
    if (chromeLeft < 0.0) chromeLeft = 0.0;
    if (mode == ApolloDuoModeOpen
        && chromeLeft < ApolloDuoRailContentLeftInset()) {
        return ApolloDuoRailContentLeftInset();
    }
    return chromeLeft;
}

// Title / Edit trailing inset. Honors hinge-sized chrome extras and
// a minimum corner gutter so the control clears rounded corners.
static inline double ApolloDuoSubsChromeTitleTrailing(double chromeRight) {
    if (chromeRight < (double)ApolloDuoSubsChromeCornerGutter) {
        return (double)ApolloDuoSubsChromeCornerGutter;
    }
    return chromeRight;
}

// Midpoint of the usable title band. Open looks centered over the
// list (right of the rail), not the full window (which includes the
// sidebar). Phone callers should not use this to move stock titles.
static inline double ApolloDuoSubsChromeTitleCenterBetween(double leftEdge,
                                                           double rightEdge) {
    return (leftEdge + rightEdge) * 0.5;
}

static inline double ApolloDuoSubsChromeTitleMaxWidth(double leftEdge,
                                                      double rightEdge,
                                                      double padding) {
    if (padding < 0.0) padding = 0.0;
    double width = rightEdge - leftEdge - 2.0 * padding;
    return width > 0.0 ? width : 0.0;
}

// FAB origin in the RedditList container. Trailing/bottom are chrome
// + corner gutter (+ optional cover-pill lift). Size stays square.
static inline ApolloDuoRailRect ApolloDuoSubsChromeFABFrame(double containerWidth,
                                                            double containerHeight,
                                                            double chromeRight,
                                                            double chromeBottom,
                                                            double buttonWidth,
                                                            double buttonHeight) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = 0.0;
    rect.height = 0.0;
    if (containerWidth <= 0.0 || containerHeight <= 0.0) return rect;
    if (buttonWidth < 1.0) buttonWidth = (double)ApolloDuoSubsChromeFABSize;
    if (buttonHeight < 1.0) buttonHeight = (double)ApolloDuoSubsChromeFABSize;
    double trail = chromeRight;
    if (trail < (double)ApolloDuoSubsChromeCornerGutter) {
        trail = (double)ApolloDuoSubsChromeCornerGutter;
    }
    trail += (double)ApolloDuoSubsChromeFABMargin;
    double bottom = chromeBottom;
    if (bottom < (double)ApolloDuoSubsChromeCornerGutter) {
        bottom = (double)ApolloDuoSubsChromeCornerGutter;
    }
    bottom += (double)ApolloDuoSubsChromeFABMargin;
    rect.width = buttonWidth;
    rect.height = buttonHeight;
    rect.x = containerWidth - trail - buttonWidth;
    rect.y = containerHeight - bottom - buttonHeight;
    if (rect.x < 0.0) rect.x = 0.0;
    if (rect.y < 0.0) rect.y = 0.0;
    return rect;
}

// Frame write guard. 0 when already on the target so viewDidLayout
// is a no-op (same hang class as 25f8a7b constraint re-toggles).
static inline int ApolloDuoSubsChromeShouldNudgeFrame(double haveX,
                                                      double haveY,
                                                      double wantX,
                                                      double wantY) {
    double dx = haveX - wantX;
    double dy = haveY - wantY;
    if (dx < 0.0) dx = -dx;
    if (dy < 0.0) dy = -dy;
    return dx > 0.5 || dy > 0.5;
}

#ifdef __cplusplus
}
#endif

#endif
