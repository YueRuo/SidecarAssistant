//
//  Created by YueRuo on 2026/11/2.
//

#import <AppKit/AppKit.h>
#include <arpa/inet.h>

static void FillRound(NSRect rect, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *sizes = @{@"icon_16x16.png": @16, @"icon_16x16@2x.png": @32,
            @"icon_32x32.png": @32, @"icon_32x32@2x.png": @64,
            @"icon_128x128.png": @128, @"icon_128x128@2x.png": @256,
            @"icon_256x256.png": @256, @"icon_256x256@2x.png": @512,
            @"icon_512x512.png": @512, @"icon_512x512@2x.png": @1024};
        NSDictionary *types = @{@"icon_16x16.png": @"icp4", @"icon_16x16@2x.png": @"ic11",
            @"icon_32x32.png": @"icp5", @"icon_32x32@2x.png": @"ic12",
            @"icon_128x128.png": @"ic07", @"icon_128x128@2x.png": @"ic13",
            @"icon_256x256.png": @"ic08", @"icon_256x256@2x.png": @"ic14",
            @"icon_512x512.png": @"ic09", @"icon_512x512@2x.png": @"ic10"};
        // Modern ICNS is a container of PNG representations with big-endian chunk lengths.
        NSMutableData *icns = [NSMutableData dataWithBytes:"icns\0\0\0\0" length:8];
        for (NSString *name in sizes) {
            NSInteger pixels = [sizes[name] integerValue];
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
            NSAffineTransform *scale = [NSAffineTransform transform];
            [scale scaleBy:pixels / 1024.0];
            [scale concat];
            NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(64, 64, 896, 896)
                xRadius:205 yRadius:205];
            NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:
                [NSColor colorWithSRGBRed:0.08 green:0.16 blue:0.32 alpha:1]
                endingColor:[NSColor colorWithSRGBRed:0.05 green:0.46 blue:0.52 alpha:1]];
            [gradient drawInBezierPath:background angle:45];
            FillRound(NSMakeRect(184, 345, 570, 402), 42, NSColor.whiteColor);
            FillRound(NSMakeRect(209, 390, 520, 332), 21,
                [NSColor colorWithSRGBRed:0.08 green:0.22 blue:0.37 alpha:1]);
            FillRound(NSMakeRect(423, 256, 88, 92), 12, NSColor.whiteColor);
            FillRound(NSMakeRect(334, 234, 267, 32), 16, NSColor.whiteColor);
            FillRound(NSMakeRect(615, 249, 234, 338), 34,
                [NSColor colorWithSRGBRed:0.05 green:0.25 blue:0.34 alpha:1]);
            FillRound(NSMakeRect(628, 261, 208, 314), 27, NSColor.whiteColor);
            FillRound(NSMakeRect(644, 286, 176, 265), 16,
                [NSColor colorWithSRGBRed:0.26 green:0.82 blue:0.74 alpha:1]);
            NSBezierPath *link = [NSBezierPath bezierPath];
            [link moveToPoint:NSMakePoint(385, 548)];
            [link lineToPoint:NSMakePoint(518, 548)];
            [link lineToPoint:NSMakePoint(480, 587)];
            [link moveToPoint:NSMakePoint(518, 548)];
            [link lineToPoint:NSMakePoint(480, 509)];
            link.lineWidth = 22;
            link.lineCapStyle = NSLineCapStyleRound;
            link.lineJoinStyle = NSLineJoinStyleRound;
            [[NSColor colorWithSRGBRed:0.31 green:0.90 blue:0.80 alpha:1] setStroke];
            [link stroke];
            [NSGraphicsContext restoreGraphicsState];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (![png writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES]) return 1;
            NSData *type = [types[name] dataUsingEncoding:NSASCIIStringEncoding];
            [icns appendData:type];
            uint32_t chunkLength = htonl((uint32_t)png.length + 8);
            [icns appendBytes:&chunkLength length:4];
            [icns appendData:png];
        }
        uint32_t totalLength = htonl((uint32_t)icns.length);
        [icns replaceBytesInRange:NSMakeRange(4, 4) withBytes:&totalLength];
        if (![icns writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]) return 1;
        return 0;
    }
}
