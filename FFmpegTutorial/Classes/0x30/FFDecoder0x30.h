//
//  FFDecoder0x30.h
//  FFmpegTutorial
//
//  Created by Matt Reach on 2022/2/17.
//
// 自定义解码器类
// 通过代理衔接输入输出

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct AVStream AVStream;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVPacket AVPacket;
typedef struct AVFrame AVFrame;
typedef struct AVRational AVRational;

@class FFDecoder0x30;
@protocol FFDecoderDelegate0x30 <NSObject>

@required
///解码器向 delegater 要一个 AVPacket
- (int)decoder:(FFDecoder0x30 *)decoder wantAPacket:(AVPacket *)packet;
///将解码后的 AVFrame 给 delegater
- (void)decoder:(FFDecoder0x30 *)decoder reveivedAFrame:(AVFrame *)frame;

@end

@interface FFDecoder0x30 : NSObject

@property (nonatomic, assign) AVFormatContext *ic;
@property (nonatomic, assign) int streamIdx;
@property (nonatomic, copy) NSString * name;
@property (nonatomic, weak) id <FFDecoderDelegate0x30> delegate;
@property (nonatomic, assign, readonly) AVStream * stream;
//for video is enum AVPixelFormat,for audio is enum AVSampleFormat,
@property (nonatomic, assign, readonly) int format;
@property (nonatomic, assign, readonly) int picWidth;
@property (nonatomic, assign, readonly) int picHeight;
@property (nonatomic, assign, readonly) AVRational frameRate;

@property (nonatomic, assign, readonly) int sampleRate;
@property (nonatomic, assign, readonly) int channelLayout;
@property (atomic, assign) BOOL eof;
/**
 打开解码器，创建解码线程;
 return 0;（没有错误）
 */
- (int)open;
//开始解码
- (void)start;
//取消解码
- (void)cancel;
//内部线程join
- (void)join;

@end


NS_ASSUME_NONNULL_END
