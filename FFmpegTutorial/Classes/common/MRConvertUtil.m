//
//  MRConvertUtil.m
//  FFmpegTutorial
//
//  Created by Matt Reach on 2020/6/3.
//

#import "MRConvertUtil.h"
#import <libavutil/frame.h>

#define BYTE_ALIGN_2(_s_) (( _s_ + 1)/2 * 2)

#define USE_BITMAP 1

@implementation MRConvertUtil

+ (CGImageRef)cgImageFromRGBFrame:(AVFrame*)frame
{
    BOOL alpha = NO;
    if (frame->format == AV_PIX_FMT_RGB24) {
        alpha = NO;
    } else if (frame->format == AV_PIX_FMT_RGBA) {
        alpha = YES;
    } else {
        NSAssert(NO, @"not support [%d] Pixel format,use RGB24 or RGBA please!",frame->format);
    }
    
    const UInt8 *rgb = frame->data[0];
    const size_t bytesPerRow = frame->linesize[0];
    const int w = frame->width;
    const int h = frame->height;
    
    ///颜色空间与 AV_PIX_FMT_RGBA 对应
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
#if USE_BITMAP
    CGContextRef bitmapContext = CGBitmapContextCreate(
        rgb,
        w,
        h,
        8, // bitsPerComponent
        bytesPerRow, // bytesPerRow
        colorSpace,
        kCGImageAlphaPremultipliedLast
    );
    CGImageRef cgImage = CGBitmapContextCreateImage(bitmapContext);
#else
    const CFIndex length = bytesPerRow * h;
    CGBitmapInfo bitMapInfo = (alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNone) | kCGBitmapByteOrderDefault;
    ///需要copy！因为frame是重复利用的；里面的数据会变化！
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, rgb, length);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGImageRef cgImage = CGImageCreate(w,
                                       h,
                                       8,
                                       alpha ? 32 : 24,
                                       bytesPerRow,
                                       colorSpace,
                                       bitMapInfo,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
#endif
    
    CGColorSpaceRelease(colorSpace);
    
    return CFAutorelease((void *)cgImage);
}

#pragma mark - YUV(NV12)-->CVPixelBufferRef Conversion

//https://stackoverflow.com/questions/25659671/how-to-convert-from-yuv-to-ciimage-for-ios
+ (CVPixelBufferRef)pixelBufferFromAVFrame:(AVFrame*)frame
{
    return [self pixelBufferFromAVFrame:frame opt:NULL];
}

+ (CVPixelBufferRef)pixelBufferFromAVFrame:(AVFrame *)picture
                                       opt:(CVPixelBufferPoolRef)poolRef
{
    if (picture->format == AV_PIX_FMT_NV21) {
        //later will swap VU. we won't modify the avframe data, because the frame can be dispaly again!
    } else {
        NSParameterAssert(picture->format == AV_PIX_FMT_NV12);
    }
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = kCVReturnError;
    if (poolRef) {
        result = CVPixelBufferPoolCreatePixelBuffer(NULL, poolRef, &pixelBuffer);
    } else {
        const int w = picture->width;
        const int h = picture->height;
        const int linesize = 32;//FFMpeg 解码数据对齐是32，这里期望CVPixelBuffer也能使用32对齐，但实际来看却是64！
        
        //AVCOL_RANGE_MPEG对应tv，AVCOL_RANGE_JPEG对应pc
        //Y′ values are conventionally shifted and scaled to the range [16, 235] (referred to as studio swing or "TV levels") rather than using the full range of [0, 255] (referred to as full swing or "PC levels").
        //https://en.wikipedia.org/wiki/YUV#Numerical_approximations
        OSType pixelFormatType = picture->color_range == AVCOL_RANGE_MPEG ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
        [attributes setObject:@(linesize) forKey:(NSString*)kCVPixelBufferBytesPerRowAlignmentKey];
        [attributes setObject:[NSDictionary dictionary] forKey:(NSString*)kCVPixelBufferIOSurfacePropertiesKey];
        
        result = CVPixelBufferCreate(kCFAllocatorDefault,
                                     w,
                                     h,
                                     pixelFormatType,
                                     (__bridge CFDictionaryRef)(attributes),
                                     &pixelBuffer);
    }
    
    if (kCVReturnSuccess == result) {
        const int h = picture->height;
        CVPixelBufferLockBaseAddress(pixelBuffer,0);
        
        // Here y_src is Y-Plane of YUV(NV12) data.
        unsigned char *y_src  = picture->data[0];
        unsigned char *y_dest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        size_t y_src_bytesPerRow  = picture->linesize[0];
        size_t y_dest_bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        /*
         将FFmpeg解码后的YUV数据塞到CVPixelBuffer中，这里必须注意不能使用以下三种形式，否则将可能导致画面错乱或者绿屏或程序崩溃！
         memcpy(y_dest, y_src, w * h);
         memcpy(y_dest, y_src, aFrame->linesize[0] * h);
         memcpy(y_dest, y_src, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * h);
         
         原因是因为FFmpeg解码后的YUV数据的linesize大小是作了字节对齐的，所以视频的w和linesize[0]很可能不相等，同样的 CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) 也是作了字节对齐的，并且对齐大小跟FFmpeg的对齐大小可能也不一样，这就导致了最坏情况下这三个值都不等！我的一个测试视频的宽度是852，FFMpeg解码使用了32字节对齐后linesize【0】是 864，而 CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) 获取到的却是 896，通过计算得出使用的是 64 字节对齐的，所以上面三种 memcpy 的写法都不靠谱！
         【字节对齐】只是为了让CPU拷贝数据速度更快，由于对齐多出来的冗余字节不会用来显示，所以填 0 即可！目前来看FFmpeg使用32个字节做对齐，而CVPixelBuffer即使指定了32缺还是使用64个字节做对齐！
         以下代码的意思是：
            按行遍历 CVPixelBuffer 的每一行；
            先把该行全部填 0 ，然后把该行的FFmpeg解码数据（包括对齐字节）复制到 CVPixelBuffer 中；
            因为有上面分析的对齐不相等问题，所以只能一行一行的处理，不能直接使用 memcpy 简单处理！
         */
        for (int i = 0; i < h; i ++) {
            bzero(y_dest, y_dest_bytesPerRow);
            memcpy(y_dest, y_src, y_src_bytesPerRow);
            y_src  += y_src_bytesPerRow;
            y_dest += y_dest_bytesPerRow;
        }
        
        // Here uv_src is UV-Plane of YUV(NV12) data.
        unsigned char *uv_src = picture->data[1];
        unsigned char *uv_dest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        size_t uv_src_bytesPerRow  = picture->linesize[1];
        size_t uv_dest_bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        
        /*
         对于 UV 的填充过程跟 Y 是一个道理，需要按行 memcpy 数据！
         */
        for (int i = 0; i < BYTE_ALIGN_2(h)/2; i ++) {
            bzero(uv_dest, uv_dest_bytesPerRow);
            memcpy(uv_dest, uv_src, uv_src_bytesPerRow);
            uv_src  += uv_src_bytesPerRow;
            uv_dest += uv_dest_bytesPerRow;
        }
        //memcpy(uv_dest, uv_src, bytesPerRowUV * BYTE_ALIGN_2(h)/2);
        
        //only swap VU for NV21
        if (picture->format == AV_PIX_FMT_NV21) {
            unsigned char *uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
            /*
             将VU交换成UV；
             */
            for (int i = 0; i < BYTE_ALIGN_2(h)/2; i ++) {
                for (int j = 0; j < uv_dest_bytesPerRow - 1; j+=2) {
                    int v = *uv;
                    *uv = *(uv + 1);
                    *(uv + 1) = v;
                    uv += 2;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    }
    return (CVPixelBufferRef)CFAutorelease(pixelBuffer);
}

@end
