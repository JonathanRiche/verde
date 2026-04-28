#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

static int copyPasteboardData(NSPasteboard *pasteboard, NSPasteboardType type, const char *mime, unsigned char **out_bytes, size_t *out_len, const char **out_mime) {
    NSData *data = [pasteboard dataForType:type];
    if (data == nil || [data length] == 0) {
        return 0;
    }

    unsigned char *bytes = malloc([data length]);
    if (bytes == NULL) {
        return -1;
    }

    memcpy(bytes, [data bytes], [data length]);
    *out_bytes = bytes;
    *out_len = [data length];
    *out_mime = mime;
    return 1;
}

static int copyData(NSData *data, const char *mime, unsigned char **out_bytes, size_t *out_len, const char **out_mime) {
    if (data == nil || [data length] == 0) {
        return 0;
    }

    unsigned char *bytes = malloc([data length]);
    if (bytes == NULL) {
        return -1;
    }

    memcpy(bytes, [data bytes], [data length]);
    *out_bytes = bytes;
    *out_len = [data length];
    *out_mime = mime;
    return 1;
}

static int copyPngFromImage(NSImage *image, unsigned char **out_bytes, size_t *out_len, const char **out_mime) {
    if (image == nil) {
        return 0;
    }

    NSData *tiff = [image TIFFRepresentation];
    if (tiff == nil || [tiff length] == 0) {
        return 0;
    }

    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return copyData(png, "image/png", out_bytes, out_len, out_mime);
}

int verde_macos_clipboard_copy_image(unsigned char **out_bytes, size_t *out_len, const char **out_mime) {
    if (out_bytes == NULL || out_len == NULL || out_mime == NULL) {
        return -1;
    }

    *out_bytes = NULL;
    *out_len = 0;
    *out_mime = NULL;

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        int copied = copyPasteboardData(pasteboard, NSPasteboardTypePNG, "image/png", out_bytes, out_len, out_mime);
        if (copied != 0) return copied;

        copied = copyPasteboardData(pasteboard, @"public.jpeg", "image/jpeg", out_bytes, out_len, out_mime);
        if (copied != 0) return copied;

        NSData *tiffData = [pasteboard dataForType:NSPasteboardTypeTIFF];
        NSImage *tiffImage = [[NSImage alloc] initWithData:tiffData];
        copied = copyPngFromImage(tiffImage, out_bytes, out_len, out_mime);
        if (copied != 0) return copied;

        NSArray *images = [pasteboard readObjectsForClasses:@[[NSImage class]] options:@{}];
        NSImage *image = [images firstObject];
        return copyPngFromImage(image, out_bytes, out_len, out_mime);
    }
}
