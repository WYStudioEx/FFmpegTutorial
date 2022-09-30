//
//  MR0x14VideoRenderer.h
//  FFmpegTutorial-iOS
//
//  Created by qianlongxu on 2020/7/10.
//  Copyright © 2020 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CoreVideo/CVPixelBuffer.h>

typedef enum : NSUInteger {
    MRViewContentModeScaleToFill0x14,
    MRViewContentModeScaleAspectFill0x14,
    MRViewContentModeScaleAspectFit0x14
} MRViewContentMode0x14;

@interface MR0x14VideoRenderer : UIView

@property (nonatomic, assign) BOOL isFullYUVRange;
@property (nonatomic, assign) MRViewContentMode0x14 contentMode;

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;


@end
