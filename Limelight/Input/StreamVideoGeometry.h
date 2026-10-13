#pragma once

#include <stdbool.h>

typedef struct {
    double width;
    double height;
} StreamVideoSize;

static inline StreamVideoSize StreamVideoSizeForViewport(double width, double height,
                                                         double aspectRatio, bool fillViewport) {
    StreamVideoSize size = {0, 0};
    if (!(width > 0) || !(height > 0) || !(aspectRatio > 0)) {
        return size;
    }
    if (fillViewport) {
        size.width = width;
        size.height = height;
    } else if (width > height * aspectRatio) {
        size.width = height * aspectRatio;
        size.height = height;
    } else {
        size.width = width;
        size.height = width / aspectRatio;
    }
    return size;
}
