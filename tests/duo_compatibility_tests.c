#include "ApolloDuoCompatibility.h"

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

int main(void) {
    Check(ApolloDuoWideWindowThreshold == 850,
          "wide-window threshold is 850pt");
    Check(ApolloDuoWideWindowMinShortSide == 500,
          "wide window needs a 500pt short side so phones never qualify");
    Check(!ApolloDuoIsWideBounds(390.0, 844.0),
          "a phone-column window is not wide");
    Check(!ApolloDuoIsWideBounds(844.0, 390.0),
          "phone landscape is not wide");
    Check(!ApolloDuoIsWideBounds(736.0, 414.0),
          "Plus landscape is not wide");
    Check(!ApolloDuoIsWideBounds(932.0, 430.0),
          "Max landscape is not wide");
    Check(!ApolloDuoIsWideBounds(800.0, 500.0),
          "the old 800pt single-canvas floor is not the wide gate");
    Check(!ApolloDuoIsWideBounds(850.0, 600.0),
          "MAX == 850 is not wide (strictly greater)");
    Check(!ApolloDuoIsWideBounds(600.0, 850.0),
          "MAX == 850 in portrait is not wide");
    Check(ApolloDuoIsWideBounds(850.5, 600.0),
          "MAX just over 850 is wide");
    Check(!ApolloDuoIsWideBounds(1000.5, 400.0),
          "a narrow-short-side window is never wide, however long");
    Check(ApolloDuoIsWideBounds(1133.0, 744.0),
          "inner Duo landscape is wide");
    Check(ApolloDuoIsWideBounds(744.0, 1133.0),
          "inner Duo portrait is wide via MAX(w,h), not width alone");
    Check(!ApolloDuoIsWideBounds(400.0, 900.0),
          "cover/front phone canvas is not wide");

    Check(ApolloDuoNeedsCanvasFill(390.0, 844.0, 1133.0, 744.0),
          "narrow portrait window on an inner canvas must fill");
    Check(ApolloDuoNeedsCanvasFill(390.0, 844.0, 744.0, 1133.0),
          "narrow window on a portrait inner canvas must fill");
    Check(ApolloDuoNeedsCanvasFill(390.0, 844.0, 700.0, 900.0),
          "letterboxed phone column still needs fill");
    Check(!ApolloDuoNeedsCanvasFill(1133.0, 744.0, 1133.0, 744.0),
          "an already-wide window matching the canvas does not refill");
    Check(!ApolloDuoNeedsCanvasFill(390.0, 844.0, 390.0, 844.0),
          "a phone window on a phone canvas is not Duo-fill");
    Check(!ApolloDuoNeedsCanvasFill(390.0, 844.0, 0.0, 0.0),
          "unknown canvas does not force a fill");

    Check(ApolloDuoModeFromBounds(0, 390.0, 844.0) == ApolloDuoModePhone,
          "single phone portrait is Phone");
    Check(ApolloDuoModeFromBounds(1, 400.0, 900.0) == ApolloDuoModeClosed,
          "cover portrait on dual display is Closed");
    Check(ApolloDuoModeFromBounds(0, 1133.0, 744.0) == ApolloDuoModeOpen,
          "wide landscape bounds are Open");
    Check(ApolloDuoModeFromBounds(0, 744.0, 1133.0) == ApolloDuoModeClosed,
          "wide portrait bounds are Closed");
    Check(ApolloDuoIsLandscapeSized(1133.0, 744.0),
          "Open window is landscape-sized");
    Check(!ApolloDuoIsLandscapeSized(400.0, 900.0),
          "Closed window is portrait-sized");

    printf("OK: %u checks\n", checks);
    return 0;
}
