//
//  MR0x141VideoRenderer.m
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2021/7/11.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "MR0x141VideoRenderer.h"
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVUtilities.h>
#import <mach/mach_time.h>
#import <GLKit/GLKit.h>
#import "renderer_pixfmt.h"
#import "MR0x141OpenGLCompiler.h"

// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_UV,
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
static GLint textureDimension[2];

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.601, which is the standard for SDTV.
static const GLfloat kColorConversion601[] = {
        1.164,  1.164, 1.164,
          0.0, -0.392, 2.017,
        1.596, -0.813,   0.0,
};

// BT.709, which is the standard for HDTV.
static const GLfloat kColorConversion709[] = {
        1.164,  1.164, 1.164,
          0.0, -0.213, 2.112,
        1.793, -0.533,   0.0,
};

// BT.601 full range (ref: http://www.equasys.de/colorconversion.html)
static const GLfloat kColorConversion601FullRange[] = {
    1.0,    1.0,    1.0,
    0.0,    -0.343, 1.765,
    1.4,    -0.711, 0.0,
};

typedef struct _Frame_Size
{
    int w;
    int h;
}Frame_Size;

@interface MR0x141VideoRenderer ()
{
    GLuint plane_textures[2];
    Frame_Size frameSize[2];
    MRViewContentMode _contentMode;
}

@property MR0x141OpenGLCompiler * openglCompiler;

@end

@implementation MR0x141VideoRenderer

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
        CGLContextObj ctx = context.CGLContextObj;
        NSLog(@"CGLContextObj:%p",ctx);
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
        self.openglCompiler = [[MR0x141OpenGLCompiler alloc] initWithvshName:@"common.vsh" fshName:@"2_sampler2DRect.fsh"];
        
        if ([self.openglCompiler compileIfNeed]) {
            // Get uniform locations.
            uniforms[UNIFORM_Y] = [self.openglCompiler getUniformLocation:"SamplerY"];
            uniforms[UNIFORM_UV] = [self.openglCompiler getUniformLocation:"SamplerUV"];
            uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = [self.openglCompiler getUniformLocation:"colorConversionMatrix"];
            
            GLint textureDimensionY = [self.openglCompiler getUniformLocation:"textureDimensionY"];
            assert(textureDimensionY >= 0);
            textureDimension[0] = textureDimensionY;
            
            GLint textureDimensionUV = [self.openglCompiler getUniformLocation:"textureDimensionUV"];
            assert(textureDimensionUV >= 0);
            textureDimension[1] = textureDimensionUV;
            
            attributers[ATTRIB_VERTEX] = [self.openglCompiler getAttribLocation:"position"];
            attributers[ATTRIB_TEXCOORD] = [self.openglCompiler getAttribLocation:"texCoord"];
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
            glGenTextures(2, plane_textures);
            glDisable(GL_DEPTH_TEST);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
            glEnable(GL_TEXTURE_RECTANGLE);
        }
    }
    
    {
        glClearColor(0.0,0.0,0.0,0.0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    
    {
        int type = CVPixelBufferGetPixelFormatType(pixelBuffer);
         
        NSAssert(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange == type || kCVPixelFormatType_420YpCbCr8BiPlanarFullRange == type,@"not supported pixel format:%d", type);
        
        IOSurfaceRef surface  = CVPixelBufferGetIOSurface(pixelBuffer);
        uint32_t cvpixfmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
        struct vt_format *f = vt_get_gl_format(cvpixfmt);
        if (!f) {
            printf("CVPixelBuffer has unsupported format type\n");
            return;
        }

        const bool planar = CVPixelBufferIsPlanar(pixelBuffer);
        const int planes  = (int)CVPixelBufferGetPlaneCount(pixelBuffer);
        assert(planar && planes == f->planes || f->planes == 1);
        
        //设置纹理和采样器的对应关系
        glUniform1i(uniforms[UNIFORM_Y], 0);
        glUniform1i(uniforms[UNIFORM_UV], 1);
        
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
        
        GLenum gl_target = GL_TEXTURE_RECTANGLE;
        
        for (int i = 0; i < f->planes; i++) {
            GLfloat w = (GLfloat)IOSurfaceGetWidthOfPlane(surface, i);
            GLfloat h = (GLfloat)IOSurfaceGetHeightOfPlane(surface, i);
            Frame_Size size = frameSize[i];
            if (size.w != w || size.h != h) {
                glUniform2f(textureDimension[i], w, h);
                size.w = w;
                size.h = h;
                frameSize[i] = size;
            }
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
        GLfloat quadVertexData [] = {
            -1 * normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
                 normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
            -1 * normalizedSamplingSize.width, normalizedSamplingSize.height,
                 normalizedSamplingSize.width, normalizedSamplingSize.height,
        };
        
        // 更新顶点数据
        glVertexAttribPointer(attributers[ATTRIB_VERTEX], 2, GL_FLOAT, 0, 0, quadVertexData);
        glEnableVertexAttribArray(attributers[ATTRIB_VERTEX]);
        
        GLfloat quadTextureData[] =  { // 坐标不对可能导致画面显示方向不对
            0, 1,
            1, 1,
            0, 0,
            1, 0,
        };
        
        glVertexAttribPointer(attributers[ATTRIB_TEXCOORD], 2, GL_FLOAT, 0, 0, quadTextureData);
        glEnableVertexAttribArray(attributers[ATTRIB_TEXCOORD]);
        
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
