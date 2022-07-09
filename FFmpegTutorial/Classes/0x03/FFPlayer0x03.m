//
//  FFPlayer0x03.m
//  FFmpegTutorial
//
//  Created by qianlongxu on 2020/4/27.
//

#import "FFPlayer0x03.h"
#import "MRThread.h"
#import "FFPlayerInternalHeader.h"
#import "FFPlayerPacketHeader.h"
#import "MRDispatch.h"
#include <libavutil/pixdesc.h>

@interface  FFPlayer0x03 ()
{
    //解码前的音频包缓存队列
    PacketQueue _audioq;
    //解码前的视频包缓存队列
    PacketQueue _videoq;
    //音频流索引
    int _audio_stream;
    //视频流索引
    int _video_stream;
    //读包完毕？
    int eof;
}

//读包线程
@property (nonatomic, strong) MRThread *readThread;
@property (atomic, assign) int abort_request;
@property (nonatomic, copy) dispatch_block_t onErrorBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferFullBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferEmptyBlock;
@property (atomic, assign) BOOL packetBufferIsFull;
@property (atomic, assign) BOOL packetBufferIsEmpty;
@property (atomic, assign, readwrite) int videoFrameCount;
@property (atomic, assign, readwrite) int audioFrameCount;

@end

@implementation  FFPlayer0x03

static int decode_interrupt_cb(void *ctx)
{
    FFPlayer0x03 *player = (__bridge FFPlayer0x03 *)ctx;
    return player.abort_request;
}

- (void)_stop
{
    //避免重复stop做无用功
    if (self.readThread) {
        self.abort_request = 1;
        //不作过多判断，因为Thread有可能处于Pending状态，比如start之后立马stop！
        //if ([self.readThread isExecuting]) {}
        [self.readThread cancel];
        [self.readThread join];
    }
    [self performSelectorOnMainThread:@selector(didStop:) withObject:self waitUntilDone:YES];
}

- (void)didStop:(id)sender
{
    self.readThread = nil;
    _video_stream = _audio_stream = -1;
    packet_queue_destroy(&_audioq);
    packet_queue_destroy(&_videoq);
}

- (void)dealloc
{
    PRINT_DEALLOC;
}

//准备
- (void)prepareToPlay
{
    if (self.readThread) {
        NSAssert(NO, @"不允许重复创建");
    }
    _video_stream = _audio_stream = -1;
    //初始化视频包队列
    packet_queue_init(&_videoq);
    //初始化音频包队列
    packet_queue_init(&_audioq);
    //初始化ffmpeg相关函数
    init_ffmpeg_once();
    
    self.readThread = [[MRThread alloc] initWithTarget:self selector:@selector(readPacketsFunc) object:nil];
    self.readThread.name = @"mr-read";
}

#pragma -mark 读包线程

//读包循环
- (void)readPacketLoop:(AVFormatContext *)formatCtx
{
    AVPacket pkt1, *pkt = &pkt1;
    const AVStream *audio_st = formatCtx->streams[_audio_stream];
    const AVStream *video_st = formatCtx->streams[_video_stream];
    //循环读包
    for (;;) {
        
        //调用了stop方法，则不再读包
        if (self.abort_request) {
            break;
        }
        
        /* 队列不满继续读，满了则休眠10 ms */
        if (_audioq.size + _videoq.size > MAX_QUEUE_SIZE
            || (stream_has_enough_packets(audio_st, _audio_stream, &_audioq) &&
                stream_has_enough_packets(video_st, _video_stream, &_videoq))) {
            
            if (!self.packetBufferIsFull) {
                self.packetBufferIsFull = YES;
                if (self.onPacketBufferFullBlock) {
                    self.onPacketBufferFullBlock();
                }
            }
            /* wait 10 ms */
            mr_msleep(10);
            continue;
        }
        
        self.packetBufferIsFull = NO;
        //读包
        int ret = av_read_frame(formatCtx, pkt);
        //延迟ms
        if (self.readPackDelay > 0) {
            mr_msleep(self.readPackDelay * 1000);
        }
        //读包出错
        if (ret < 0) {
            //读到最后结束了
            if ((ret == AVERROR_EOF || avio_feof(formatCtx->pb)) && !eof) {
                //最后放一个空包进去
                if (_video_stream >= 0) {
                    packet_queue_put_nullpacket(&_videoq, _video_stream);
                }
                
                if (_audio_stream >= 0) {
                    packet_queue_put_nullpacket(&_audioq, _audio_stream);
                }
                //标志为读包结束
                eof = 1;
            }
            
            if (formatCtx->pb && formatCtx->pb->error) {
                break;
            }
            
            mr_msleep(10);
            continue;
        } else {
            //音频包入音频队列
            if (pkt->stream_index == _audio_stream) {
                packet_queue_put(&_audioq, pkt);
            }
            //视频包入视频队列
            else if (pkt->stream_index == _video_stream) {
                packet_queue_put(&_videoq, pkt);
            }
            //其他包释放内存忽略掉
            else {
                av_packet_unref(pkt);
            }
        }
    }
}

- (void)readPacketsFunc
{
    NSParameterAssert(self.contentPath);
    
    if (![self.contentPath hasPrefix:@"/"]) {
        _init_net_work_once();
    }
    
    AVFormatContext *formatCtx = avformat_alloc_context();
    
    if (!formatCtx) {
        self.error = _make_nserror_desc(FFPlayerErrorCode_AllocFmtCtxFailed, @"创建 AVFormatContext 失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    formatCtx->interrupt_callback.callback = decode_interrupt_cb;
    formatCtx->interrupt_callback.opaque = (__bridge void *)self;
    
    /*
     打开输入流，读取文件头信息，不会打开解码器；
     */
    //低版本是 av_open_input_file 方法
    const char *moviePath = [self.contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //打开文件流，读取头信息；
    if (0 != avformat_open_input(&formatCtx, moviePath , NULL, NULL)) {
        //释放内存
        avformat_free_context(formatCtx);
        //当取消掉时，不给上层回调
        if (self.abort_request) {
            return;
        }
        self.error = _make_nserror_desc(FFPlayerErrorCode_OpenFileFailed, @"文件打开失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    /* 刚才只是打开了文件，检测了下文件头而已，并不知道流信息；因此开始读包以获取流信息
     设置读包探测大小和最大时长，避免读太多的包！
    */
    formatCtx->probesize = 500 * 1024;
    formatCtx->max_analyze_duration = 5 * AV_TIME_BASE;
#if DEBUG
    NSTimeInterval begin = [[NSDate date] timeIntervalSinceReferenceDate];
#endif
    if (0 != avformat_find_stream_info(formatCtx, NULL)) {
        avformat_close_input(&formatCtx);
        self.error = _make_nserror_desc(FFPlayerErrorCode_StreamNotFound, @"不能找到流！");
        [self performErrorResultOnMainThread];
        //出错了，销毁下相关结构体
        avformat_close_input(&formatCtx);
        return;
    }
    
#if DEBUG
    NSTimeInterval end = [[NSDate date] timeIntervalSinceReferenceDate];
    //用于查看详细信息，调试的时候打出来看下很有必要
    av_dump_format(formatCtx, 0, moviePath, false);
    
    MRFF_DEBUG_LOG(@"avformat_find_stream_info coast time:%g",end-begin);
#endif

    //遍历所有的流
    for (int i = 0; i < formatCtx->nb_streams; i++) {
        
        AVStream *stream = formatCtx->streams[i];
        
        AVCodecContext *codecCtx = avcodec_alloc_context3(NULL);
        if (!codecCtx){
            continue;
        }
        
        int ret = avcodec_parameters_to_context(codecCtx, stream->codecpar);
        if (ret < 0){
            avcodec_free_context(&codecCtx);
            continue;
        }
        
        av_codec_set_pkt_timebase(codecCtx, stream->time_base);
        
        //AVCodecContext *codec = stream->codec;
        enum AVMediaType codec_type = codecCtx->codec_type;
        switch (codec_type) {
                //音频流
            case AVMEDIA_TYPE_AUDIO:
            {
                _audio_stream = stream->index;
            }
                break;
                //视频流
            case AVMEDIA_TYPE_VIDEO:
            {
                _video_stream = stream->index;
            }
                break;
            case AVMEDIA_TYPE_ATTACHMENT:
            {
                MRFF_DEBUG_LOG(@"附加信息流:%d",i);
            }
                break;
            default:
            {
                MRFF_DEBUG_LOG(@"其他流:%d",i);
            }
                break;
        }
        
        avcodec_free_context(&codecCtx);
    }
    
    //读包循环
    [self readPacketLoop:formatCtx];
    //读包线程结束了，销毁下相关结构体
    avformat_close_input(&formatCtx);
}

- (void)performErrorResultOnMainThread
{
    mr_sync_main_queue(^{
        if (self.onErrorBlock) {
            self.onErrorBlock();
        }
    });
}

- (void)play
{
    [self.readThread start];
}

- (void)asyncStop
{
    [self performSelectorInBackground:@selector(_stop) withObject:self];
}

- (void)onError:(dispatch_block_t)block
{
    self.onErrorBlock = block;
}

- (void)onPacketBufferFull:(dispatch_block_t)block
{
    self.onPacketBufferFullBlock = block;
}

- (void)onPacketBufferEmpty:(dispatch_block_t)block
{
    self.onPacketBufferEmptyBlock = block;
}

- (MR_PACKET_SIZE)peekPacketBufferStatus
{
    return (MR_PACKET_SIZE){_videoq.nb_packets,_audioq.nb_packets,0};
}

- (BOOL)consumePackets
{
    AVPacket audio_pkt;
    int audio_not_empty = packet_queue_get(&_audioq, &audio_pkt, 0);
    if (audio_not_empty) {
        av_packet_unref(&audio_pkt);
    }
    AVPacket video_pkt;
    int video_not_empty = packet_queue_get(&_videoq, &video_pkt, 0);
    if (video_not_empty) {
        av_packet_unref(&video_pkt);
    }
    self.packetBufferIsFull = NO;
    if (!self.packetBufferIsEmpty) {
        if (!audio_not_empty && !video_not_empty) {
            if (self.onPacketBufferEmptyBlock) {
                self.onPacketBufferEmptyBlock();
            }
            self.packetBufferIsEmpty = YES;
        }
    }
    return audio_not_empty || video_not_empty;
}

- (void)consumeAllPackets
{
    packet_queue_flush(&_audioq);
    packet_queue_flush(&_videoq);
    self.packetBufferIsFull = NO;
    if (!self.packetBufferIsEmpty) {
        if (self.onPacketBufferEmptyBlock) {
            self.onPacketBufferEmptyBlock();
        }
        self.packetBufferIsEmpty = YES;
    }
}

@end
