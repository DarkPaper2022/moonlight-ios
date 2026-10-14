#pragma once

#include <stdbool.h>

typedef struct {
    double width;
    double height;
} StreamVideoSize;

static inline StreamVideoSize StreamVideoSizeForViewport(double width, double height,
                                                         double aspectRatio) {
    StreamVideoSize size = {0, 0};
    if (!(width > 0) || !(height > 0) || !(aspectRatio > 0)) {
        return size;
    }
    if (width > height * aspectRatio) {
        size.width = height * aspectRatio;
        size.height = height;
    } else {
        size.width = width;
        size.height = width / aspectRatio;
    }
    return size;
}

typedef struct {
    int width;
    int height;
} StreamPixelSize;

static inline StreamPixelSize StreamNativePixelsForViewport(double width, double height, double scale) {
    StreamPixelSize size = {0, 0};
    if (!(width > 0) || !(height > 0) || !(scale > 0)) {
        return size;
    }
    // YUV 4:2:0 encoders need even dimensions; use actual drawable view points,
    // not the physical display's full portrait pixel grid.
    double pixelWidth = width * scale;
    double pixelHeight = height * scale;
    if (pixelWidth > 8192.0) pixelWidth = 8192.0;
    if (pixelHeight > 8192.0) pixelHeight = 8192.0;
    size.width = ((int)pixelWidth / 2) * 2;
    size.height = ((int)pixelHeight / 2) * 2;
    if (size.width < 256) size.width = 256;
    if (size.height < 256) size.height = 256;
    return size;
}

static inline bool StreamResolutionIsLegacyPortraitNative(int width, int height,
                                                           double screenWidth, double screenHeight) {
    double shortSide = screenWidth < screenHeight ? screenWidth : screenHeight;
    double longSide = screenWidth > screenHeight ? screenWidth : screenHeight;
    return width < height && width == (int)shortSide && height == (int)longSide;
}
