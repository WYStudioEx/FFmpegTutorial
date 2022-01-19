//
//  MR0x152VideoRenderer.m
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2022/1/18.
//  Copyright © 2022 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "MR0x152VideoRenderer.h"
#import <OpenGL/gl.h>
#import <OpenGL/gl3.h>
#import <OpenGL/glext.h>
#import <OpenGL/gl3ext.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVUtilities.h>
#import <mach/mach_time.h>
#import <GLKit/GLKit.h>
#import "renderer_pixfmt.h"
#import "MROpenGLCompiler.h"

#define MY_GL_TARGET GL_TEXTURE_2D //GL_TEXTURE_RECTANGLE

// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_U,
    UNIFORM_V,
    UNIFORM_COLOR_CONVERSION_MATRIX,
    NUM_UNIFORMS
};

// Attribute index.
enum
{
    ATTRIB_VERTEX,
    ATTRIB_TEXCOORD,
    NUM_ATTRIBUTES
};

static GLint uniforms[NUM_UNIFORMS];
static GLint attributers[NUM_ATTRIBUTES];

@interface MR0x152VideoRenderer ()
{
    GLuint plane_textures[3];
    MRViewContentMode _contentMode;
    /// 顶点对象
    GLuint _VBO;
    GLuint _VAO;
}

@property MROpenGLCompiler * openglCompiler;

@end

@implementation MR0x152VideoRenderer

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        NSOpenGLPixelFormatAttribute attrs[] =
        {
            NSOpenGLPFAAccelerated,
            NSOpenGLPFANoRecovery,
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFADepthSize, 24,
            NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
            0
        };
        NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
        
        if (!pf)
        {
            NSLog(@"No OpenGL pixel format");
        }
        
        NSOpenGLContext* context = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil];
        
    #if ESSENTIAL_GL_PRACTICES_SUPPORT_GL3 && defined(DEBUG)
        // When we're using a CoreProfile context, crash if we call a legacy OpenGL function
        // This will make it much more obvious where and when such a function call is made so
        // that we can remove such calls.
        // Without this we'd simply get GL_INVALID_OPERATION error for calling legacy functions
        // but it would be more difficult to see where that function was called.
        CGLEnable([context CGLContextObj], kCGLCECrashOnRemovedFunctions);
    #endif
        [self setPixelFormat:pf];
        [self setOpenGLContext:context];
    #if 1 || SUPPORT_RETINA_RESOLUTION
        // Opt-In to Retina resolution
        [self setWantsBestResolutionOpenGLSurface:YES];
    #endif // SUPPORT_RETINA_RESOLUTION
    }
    return self;
}

- (void)setupOpenGLProgram
{
    if (!self.openglCompiler) {
        self.openglCompiler = [[MROpenGLCompiler alloc] initWithvshName:@"common_v3.vsh" fshName:@"3_sampler2D_v3.fsh"];
        
        if ([self.openglCompiler compileIfNeed]) {
            // Get uniform locations.
            uniforms[UNIFORM_Y] = [self.openglCompiler getUniformLocation:"SamplerY"];
            uniforms[UNIFORM_U] = [self.openglCompiler getUniformLocation:"SamplerU"];
            uniforms[UNIFORM_V] = [self.openglCompiler getUniformLocation:"SamplerV"];
            
            uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = [self.openglCompiler getUniformLocation:"colorConversionMatrix"];
            
            attributers[ATTRIB_VERTEX]   = [self.openglCompiler getAttribLocation:"position"];
            attributers[ATTRIB_TEXCOORD] = [self.openglCompiler getAttribLocation:"texCoord"];
            
            glGenVertexArrays(1, &_VAO);
            /// 创建顶点缓存对象
            glGenBuffers(1, &_VBO);
            
            glBindVertexArray(_VAO);
            /// 绑定顶点缓存对象到当前的顶点位置,之后对GL_ARRAY_BUFFER的操作即是对_VBO的操作
            /// 同时也指定了_VBO的对象类型是一个顶点数据对象
            glBindBuffer(GL_ARRAY_BUFFER, _VBO);
        }
    }
}

- (void)resetViewPort
{
    // We draw on a secondary thread through the display link. However, when
    // resizing the view, -drawRect is called on the main thread.
    // Add a mutex around to avoid the threads accessing the context
    // simultaneously when resizing.
    CGLLockContext([[self openGLContext] CGLContextObj]);
    
    // Get the view size in Points
    NSRect viewRectPoints = [self bounds];
    
#if SUPPORT_RETINA_RESOLUTION
    
    // Rendering at retina resolutions will reduce aliasing, but at the potential
    // cost of framerate and battery life due to the GPU needing to render more
    // pixels.
    
    // Any calculations the renderer does which use pixel dimentions, must be
    // in "retina" space.  [NSView convertRectToBacking] converts point sizes
    // to pixel sizes.  Thus the renderer gets the size in pixels, not points,
    // so that it can set it's viewport and perform and other pixel based
    // calculations appropriately.
    // viewRectPixels will be larger than viewRectPoints for retina displays.
    // viewRectPixels will be the same as viewRectPoints for non-retina displays
    NSRect viewRectPixels = [self convertRectToBacking:viewRectPoints];
    
#else //if !SUPPORT_RETINA_RESOLUTION
    
    // App will typically render faster and use less power rendering at
    // non-retina resolutions since the GPU needs to render less pixels.
    // There is the cost of more aliasing, but it will be no-worse than
    // on a Mac without a retina display.
    
    // Points:Pixels is always 1:1 when not supporting retina resolutions
    NSRect viewRectPixels = viewRectPoints;
    
#endif // !SUPPORT_RETINA_RESOLUTION
    
    GLsizei backingWidth = viewRectPixels.size.width;
    GLsizei backingHeight = viewRectPixels.size.height;
    // Set the new dimensions in our renderer
    glViewport(0, 0, backingWidth, backingHeight);
    CGLUnlockContext([[self openGLContext] CGLContextObj]);
}

- (void)initGL
{
    // The reshape function may have changed the thread to which our OpenGL
    // context is attached before prepareOpenGL and initGL are called.  So call
    // makeCurrentContext to ensure that our OpenGL context current to this
    // thread (i.e. makeCurrentContext directs all OpenGL calls on this thread
    // to [self openGLContext])
    [[self openGLContext] makeCurrentContext];
    
    // Synchronize buffer swaps with vertical refresh rate
    GLint swapInt = 1;
    [[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
}

- (void)prepareOpenGL
{
    [super prepareOpenGL];

    // Make all the OpenGL calls to setup rendering
    //  and build the necessary rendering objects
    [self initGL];
}

- (void)reshape
{
    [super reshape];
    [self resetViewPort];
}

- (void)uploadTextureV1:(CVPixelBufferRef _Nonnull)pixelBuffer
{
    GLenum gl_target = MY_GL_TARGET;
    
    uint32_t cvpixfmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    struct vt_format * f = vt_get_gl_format(cvpixfmt);
    
    if (!f) {
        NSAssert(!f,@"please add pixel format:%d to renderer_pixfmt.h", cvpixfmt);
        return;
    }
    
    const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
    assert(planar && planes == f->planes || f->planes == 1);
    
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    
    for (int i = 0; i < f->planes; i++) {
        GLfloat w = (GLfloat)IOSurfaceGetWidthOfPlane(surface, i);
        GLfloat h = (GLfloat)IOSurfaceGetHeightOfPlane(surface, i);
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(gl_target, plane_textures[i]);
        
        struct vt_gl_plane_format plane_format = f->gl[i];
        CGLError err = CGLTexImageIOSurface2D(CGLGetCurrentContext(),
                                              gl_target,
                                              plane_format.gl_internal_format,
                                              w,
                                              h,
                                              plane_format.gl_format,
                                              plane_format.gl_type,
                                              surface,
                                              i);

        if (err != kCGLNoError) {
            NSLog(@"error creating IOSurface texture for plane %d: %s\n",
                   0, CGLErrorString(err));
            return;
        } else {
            glTexParameteri(gl_target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(gl_target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
    }
}

- (void)uploadTextureV2:(CVPixelBufferRef _Nonnull)pixelBuffer
{
    GLenum gl_target = MY_GL_TARGET;
    
    uint32_t cvpixfmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    struct vt_format * f = vt_get_gl_format(cvpixfmt);
    
    if (!f) {
        NSAssert(!f,@"please add pixel format:%d to renderer_pixfmt.h", cvpixfmt);
        return;
    }
    
    const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
    const int planes  = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
    assert(planar && planes == f->planes || f->planes == 1);
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    for (int i = 0; i < f->planes; i++) {
        GLfloat w = (GLfloat)CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
        GLfloat h = (GLfloat)CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(gl_target, plane_textures[i]);
        
        struct vt_gl_plane_format plane_format = f->gl[i];
        
        glTexImage2D(gl_target, 0, GL_RED, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i));
        
        CGLError err = kCGLNoError;

        if (err != kCGLNoError) {
            NSLog(@"error creating IOSurface texture for plane %d: %s\n",
                   0, CGLErrorString(err));
            return;
        } else {
            glTexParameteri(gl_target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(gl_target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(gl_target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}


- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    [[self openGLContext] makeCurrentContext];
    CGLLockContext([[self openGLContext] CGLContextObj]);
    //active opengl program
    {
        [self setupOpenGLProgram];
        [self.openglCompiler active];
    }
    
    {
        if (0 == plane_textures[0]) {
            glGenTextures(sizeof(plane_textures)/sizeof(GLuint), plane_textures);
            for (int i = 0; i < sizeof(plane_textures)/sizeof(GLuint); i++) {
                glBindTexture(GL_TEXTURE_2D, plane_textures[i]);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glGenerateMipmap(GL_TEXTURE_2D);
                glBindTexture(GL_TEXTURE_2D, 0);
            }
        }
    }
    
    {
        glDisable(GL_DEPTH_TEST);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        //glEnable(GL_TEXTURE_2D);
        MR_checkGLError("glEnable GL_TEXTURE_2D");
        glClearColor(0.0,0.0,0.0,0.0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    
    {
        int type = CVPixelBufferGetPixelFormatType(pixelBuffer);
         
        NSAssert(kCVPixelFormatType_420YpCbCr8Planar == type || kCVPixelFormatType_420YpCbCr8PlanarFullRange == type,@"not supported pixel format:%d", type);
        
        CFTypeRef colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
        
        const GLfloat * preferredConversion = NULL;
        if (colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            BOOL isFullYUVRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange == type;
            if (isFullYUVRange) {
                preferredConversion = kColorConversion601FullRange;
            }
            else {
                preferredConversion = kColorConversion601;
            }
        }
        else {
            preferredConversion = kColorConversion709;
        }
        glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, preferredConversion);
        
        //设置纹理和采样器的对应关系
        glUniform1i(uniforms[UNIFORM_Y], 0);
        glUniform1i(uniforms[UNIFORM_U], 1);
        glUniform1i(uniforms[UNIFORM_V], 2);
        
        [self uploadTextureV2:pixelBuffer];
        
        // Compute normalized quad coordinates to draw the frame into.
        CGSize normalizedSamplingSize = CGSizeMake(1.0, 1.0);

        if (_contentMode == MRViewContentModeScaleAspectFit || _contentMode == MRViewContentModeScaleAspectFill) {
            const size_t pictureWidth = CVPixelBufferGetWidth(pixelBuffer);
            const size_t pictureHeight = CVPixelBufferGetHeight(pixelBuffer);
            // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
            CGRect vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(CGSizeMake(pictureWidth, pictureHeight), self.layer.bounds);

            CGSize cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width/self.layer.bounds.size.width, vertexSamplingRect.size.height/self.layer.bounds.size.height);

            // hold max
            if (_contentMode == MRViewContentModeScaleAspectFit) {
                if (cropScaleAmount.width > cropScaleAmount.height) {
                    normalizedSamplingSize.width = 1.0;
                    normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width;
                }
                else {
                    normalizedSamplingSize.height = 1.0;
                    normalizedSamplingSize.width = cropScaleAmount.width/cropScaleAmount.height;
                }
            } else if (_contentMode == MRViewContentModeScaleAspectFill) {
                // hold min
                if (cropScaleAmount.width > cropScaleAmount.height) {
                    normalizedSamplingSize.height = 1.0;
                    normalizedSamplingSize.width = cropScaleAmount.width/cropScaleAmount.height;
                }
                else {
                    normalizedSamplingSize.width = 1.0;
                    normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width;
                }
            }
        }

        /*
         The quad vertex data defines the region of 2D plane onto which we draw our pixel buffers.
         Vertex data formed using (-1,-1) and (1,1) as the bottom left and top right coordinates respectively, covers the entire screen.
         */
        GLfloat quadData [] = {
            -1 * normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
                 normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
            -1 * normalizedSamplingSize.width, normalizedSamplingSize.height,
                 normalizedSamplingSize.width, normalizedSamplingSize.height,
            //Texture Postition
            0, 1,
            1, 1,
            0, 0,
            1, 0,
        };
        
        /// 将CPU数据发送到GPU,数据类型GL_ARRAY_BUFFER
        /// GL_STATIC_DRAW 表示数据不会被修改,将其放置在GPU显存的更合适的位置,增加其读取速度
        glBufferData(GL_ARRAY_BUFFER, sizeof(quadData), quadData, GL_DYNAMIC_DRAW);
        
        /// 指定顶点着色器位置为0的参数的数据读取方式与数据类型
        /// 第一个参数: 参数位置
        /// 第二个参数: 一次读取数据
        /// 第三个参数: 数据类型
        /// 第四个参数: 是否归一化数据
        /// 第五个参数: 间隔多少个数据读取下一次数据
        /// 第六个参数: 指定读取第一个数据在顶点数据中的偏移量
        glVertexAttribPointer(attributers[ATTRIB_VERTEX], 2, GL_FLOAT, GL_FALSE, 0, (void*)0);
        /// 启用顶点着色器中位置为0的参数
        glEnableVertexAttribArray(attributers[ATTRIB_VERTEX]);
        
        // texture coord attribute
        glVertexAttribPointer(attributers[ATTRIB_TEXCOORD], 2, GL_FLOAT, GL_FALSE, 0, (void*)(8 * sizeof(float)));
        glEnableVertexAttribArray(attributers[ATTRIB_TEXCOORD]);
        
        // 更新顶点数据
        glEnableVertexAttribArray(attributers[ATTRIB_VERTEX]);
        glEnableVertexAttribArray(attributers[ATTRIB_TEXCOORD]);
        
        
        glBindVertexArray(_VAO);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    CGLFlushDrawable([[self openGLContext] CGLContextObj]);
    CGLUnlockContext([[self openGLContext] CGLContextObj]);
}

- (void)setContentMode:(MRViewContentMode)contentMode
{
    _contentMode = contentMode;
}

- (MRViewContentMode)contentMode
{
    return _contentMode;
}

@end
