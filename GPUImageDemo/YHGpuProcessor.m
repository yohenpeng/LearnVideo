//
//  YHGpuProcessor.m
//  GPUImageDemo
//
//  Created by 彭依汉 on 2019/9/19.
//  Copyright © 2019 彭依汉. All rights reserved.
//

#import "YHGpuProcessor.h"
#import "YHImageFilter.h"
//#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VideoToolbox.h>

static const int kYTextureUnit = 0;
static const int kUvTextureUnit = 1;

///////////////////////////////////////////////////////////////////////////////////////////////
// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.601, which is the standard for SDTV.
const GLfloat gpuColorConversion601[] = {
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
};

// BT.709, which is the standard for HDTV.
const GLfloat gpuColorConversion709[] = {
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
};

// BT.601 full range (ref: http://www.equasys.de/colorconversion.html )
const GLfloat gpuColorConversion601FullRange[] = {
    1.0,    1.0,    1.0,
    0.0,    -0.343, 1.765,
    1.4,    -0.711, 0.0,
};

@interface YHGpuProcessor (){
    
    GLProgram * yuvConversionProgram;
    
    GLint yuvConversionPositionAttribute, yuvConversionTextureCoordinateAttribute;
    
    GLint yuvConversionLuminanceTextureUniform, yuvConversionChrominanceTextureUniform;
    
    GLint yuvConversionMatrixUniform;
    
    CVOpenGLESTextureRef _yTextureRef;
    CVOpenGLESTextureRef _uvTextureRef;
}

@property (weak, nonatomic)GPUImageView *weakImageView;

@property (strong, nonatomic) GPUImageSketchFilter *sepiaFilter;

@property (strong, nonatomic) YHImageFilter *yhImageFilter;

@property (strong, nonatomic) GPUImageRawDataOutput *rawDataOutput;

@property (assign, nonatomic) VTCompressionSessionRef encodeSessionRef;

@property (strong, nonatomic) NSFileHandle *fileHandle;

@end

@implementation YHGpuProcessor

#pragma mark ----------
#pragma mark ---------- life cycle ------------
- (instancetype)initWithGpuImageView:(GPUImageView *)imageView{
    self = [super init];
    if(self){
        //先输出到YHImageFilter滤镜，然后再输出到GPUImageView
        self.weakImageView = imageView;
        [self addTarget:self.sepiaFilter];
        [self.sepiaFilter addTarget:self.weakImageView];
        [self.sepiaFilter addTarget:self.rawDataOutput];
        [self initYuvConversion];
    }
    return self;
}

- (void)initYuvConversion
{
    dispatch_sync([GPUImageContext sharedContextQueue], ^{
        [GPUImageContext useImageProcessingContext];
 
        NSString *fragmentShaderString = nil;

        //片元着色器
        fragmentShaderString = kGPUImageYUVVideoRangeConversionForLAFragmentShaderString;
        
        //着色器程序
        yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:fragmentShaderString];
 
        //链接着色器程序
        if (!yuvConversionProgram.initialized) {
            [yuvConversionProgram addAttribute:@"position"];
            [yuvConversionProgram addAttribute:@"inputTextureCoordinate"];
            
            if (![yuvConversionProgram link]) {
                //NSAssert(NO, @"Filter shader link failed");
            }
        }
        yuvConversionPositionAttribute             = [yuvConversionProgram attributeIndex:@"position"];
        yuvConversionTextureCoordinateAttribute = [yuvConversionProgram attributeIndex:@"inputTextureCoordinate"];
        
        //明亮度、色彩度纹理采样器
        yuvConversionLuminanceTextureUniform     = [yuvConversionProgram uniformIndex:@"luminanceTexture"];
        yuvConversionChrominanceTextureUniform     = [yuvConversionProgram uniformIndex:@"chrominanceTexture"];
        
        //颜色转换矩阵
        yuvConversionMatrixUniform                 = [yuvConversionProgram uniformIndex:@"colorConversionMatrix"];
        
        [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
        //启用两个属性
        glEnableVertexAttribArray(yuvConversionPositionAttribute);
        glEnableVertexAttribArray(yuvConversionTextureCoordinateAttribute);
    });
}

#pragma mark ----------
#pragma mark ---------- public func ------------
- (void)process:(CMSampleBufferRef)sampleBuffer{
    __weak __typeof(self) weakSelf = self;
    dispatch_sync([GPUImageContext sharedContextQueue], ^{
        __strong __typeof(self) strongSelf = weakSelf;
        [strongSelf process420FSample:sampleBuffer];
    });
}

- (void)process420FSample:(CMSampleBufferRef)sampleBuffer{
    GPUImageRawDataOutput *output = [self preprocess:sampleBuffer];
}

- (GPUImageRawDataOutput *)preprocess:(CMSampleBufferRef)sampleBuffer{
    CMTime currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    int bufferWidth = (int)CVPixelBufferGetWidth(imageBuffer);
    int bufferHeight = (int)CVPixelBufferGetHeight(imageBuffer);
    //获得颜色转换矩阵
    const CGFloat *preferredConversion = [self getPreferredConversion:imageBuffer];
    
    [GPUImageContext useImageProcessingContext];
    
    BOOL bFlag = [GPUImageContext supportsFastTextureUpload];
    
    if(bFlag){
        if(CVPixelBufferGetPlaneCount(imageBuffer) > 0){
            //这里先取到y平面和uv平面
            bool res = [self loadTexture:&_yTextureRef pixelBuffer:imageBuffer planeIndex:0 pixelFormat:GL_LUMINANCE];
            res &= [self loadTexture:&_uvTextureRef pixelBuffer:imageBuffer planeIndex:1 pixelFormat:GL_LUMINANCE_ALPHA];
            if(!res){
                NSLog(@"Live:XAV:Gpu load texture failed.");
                return nil;
            }
            
            [self convertYuvToRgb:preferredConversion width:bufferWidth height:bufferHeight];
            int rotatedImageBufferWidth = bufferWidth, rotatedImageBufferHeight = bufferHeight;
            [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:rotatedImageBufferWidth height:rotatedImageBufferHeight time:currentTime];
        }
    } else {
        CVPixelBufferLockBaseAddress(imageBuffer, 0);
        int bytesPerRow = (int)CVPixelBufferGetBytesPerRow(imageBuffer);
        outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(bytesPerRow/4, bufferHeight) onlyTexture:YES];
        [outputFramebuffer activateFramebuffer];
        
        glBindTexture(GL_TEXTURE_2D, [outputFramebuffer texture]);
        
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bytesPerRow/4, bufferHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(imageBuffer));
        [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:(bytesPerRow/4) height:bufferHeight time:currentTime];
        
        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    }
    return self.rawDataOutput;
}


- (void)convertYuvToRgb:(const GLfloat*)preferredConversion width:(int)width height:(int)height;
{
    [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
    
    int rotatedImageBufferWidth = width, rotatedImageBufferHeight = height;
    
    CGSize szFrame =CGSizeMake(rotatedImageBufferWidth, rotatedImageBufferHeight) ;
    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:szFrame
                                                                           textureOptions:self.outputTextureOptions
                                                                              onlyTexture:NO];
    [outputFramebuffer activateFramebuffer];
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    glActiveTexture(GL_TEXTURE0 + kYTextureUnit);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_yTextureRef));
    glUniform1i(yuvConversionLuminanceTextureUniform, kYTextureUnit);
    
    glActiveTexture(GL_TEXTURE0 + kUvTextureUnit);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_uvTextureRef));
    glUniform1i(yuvConversionChrominanceTextureUniform, kUvTextureUnit);
    
    glUniformMatrix3fv(yuvConversionMatrixUniform, 1, GL_FALSE, preferredConversion);
    
    glVertexAttribPointer(yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, [GPUImageFilter textureCoordinatesForRotation:kGPUImageNoRotation]);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}


- (BOOL)loadTexture:(CVOpenGLESTextureRef *)textureOut
        pixelBuffer:(CVPixelBufferRef)pixelBuffer
         planeIndex:(int)planeIndex
        pixelFormat:(GLenum)pixelFormat {
    const int width = (int)CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex);
    const int height = (int)CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex);
    if (*textureOut) {
        CFRelease(*textureOut);
        *textureOut = nil;
    }
    CVReturn ret = CVOpenGLESTextureCacheCreateTextureFromImage(
                                                                kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], pixelBuffer, NULL, GL_TEXTURE_2D, pixelFormat, width,
                                                                height, pixelFormat, GL_UNSIGNED_BYTE, planeIndex, textureOut);
    if (ret != kCVReturnSuccess) {
        CFRelease(*textureOut);
        *textureOut = nil;
        return NO;
    }
    
    NSAssert(CVOpenGLESTextureGetTarget(*textureOut) == GL_TEXTURE_2D, @"Unexpected GLES texture target");
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(*textureOut));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return YES;
}

- (void)updateTargetsForVideoCameraUsingCacheTextureAtWidth:(int)bufferWidth  height:(int)bufferHeight  time:(CMTime)currentTime;
{
    // First, update all the framebuffers in the targets
    for (id<GPUImageInput> currentTarget in targets) {
        if ([currentTarget enabled]) {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates) {
                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:textureIndexOfTarget];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
            }
        }
    }
    
    // Then release our hold on the local framebuffer to send it back to the cache as soon as it's no longer needed
    [outputFramebuffer unlock];
//    outputFramebuffer = nil;
    
    // Finally, trigger rendering as needed
    for (id<GPUImageInput> currentTarget in targets) {
        if ([currentTarget enabled]) {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates) {
                [currentTarget newFrameReadyAtTime:currentTime atIndex:textureIndexOfTarget];
            }
        }
    }
}

- (const GLfloat*)getPreferredConversion:(CVImageBufferRef)imageBuffer;
{
    CFTypeRef colorAttachments = CVBufferGetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
    if (colorAttachments) {
        if (CFStringCompare( (CFStringRef)colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) != kCFCompareEqualTo) {
            return gpuColorConversion709;
        }
    }
    
    return gpuColorConversion601;
}

- (GPUImageSketchFilter *)sepiaFilter{
    if(!_sepiaFilter){
        _sepiaFilter = [GPUImageSketchFilter new];
    }
    return _sepiaFilter;
}

- (YHImageFilter *)yhImageFilter{
    if(!_yhImageFilter){
        _yhImageFilter = [YHImageFilter new];
    }
    return _yhImageFilter;
}



- (GPUImageRawDataOutput *)rawDataOutput{
    if(!_rawDataOutput){
        _rawDataOutput = [[GPUImageRawDataOutput alloc]initWithImageSize:CGSizeMake(720, 1280) resultsInBGRAFormat:YES];
        __weak GPUImageRawDataOutput *weakOutput = _rawDataOutput;
        __weak typeof(self) weakSelf = self;
        [_rawDataOutput setNewFrameAvailableBlock:^{
            __strong GPUImageRawDataOutput *strongOutput = weakOutput;
            __strong typeof(self) strongSelf = weakSelf;
            
            [strongSelf createCompressSessionIfNeed];
            [strongOutput lockFramebufferForReading];
            GLubyte *outputBytes = [strongOutput rawBytesForImage];
            NSInteger bytesPerRow = [strongOutput bytesPerRowInOutput];
            CVPixelBufferRef pixelBuffer = NULL;
            CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 720, 1280, kCVPixelFormatType_32BGRA, outputBytes, bytesPerRow, nil, nil, nil, &pixelBuffer);
            [strongOutput unlockFramebufferAfterReading];
            
            if(pixelBuffer == NULL){
                return;
            }
            
            static int64_t frameId = 1;
            CMTime presentationTimeStamp = CMTimeMake(frameId++, 1000);
            VTEncodeInfoFlags flags;
            
            OSStatus statusCode = VTCompressionSessionEncodeFrame(strongSelf.encodeSessionRef, pixelBuffer, presentationTimeStamp, kCMTimeInvalid, NULL, NULL, &flags);
            if(statusCode != noErr){
                NSLog(@"H264 Comporess Error");
                return;
            }
            NSLog(@"H264 Compress Success");
            
        }];
    }
    return _rawDataOutput;
}

static BOOL bNeedCreateComporessSession = YES;
- (void)createCompressSessionIfNeed{
    
    if(bNeedCreateComporessSession){
        VTCompressionSessionRef sessionRef;
        OSStatus createStatus = VTCompressionSessionCreate(NULL, 720, 1280, kCMVideoCodecType_H264, NULL, NULL, NULL,didCompressH264 ,(__bridge void *)(self), &sessionRef);
        if(createStatus == noErr){
            //设置实时编码
            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
            
            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
            
            //不要B帧
            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
            
            //设置GOP
            int frameIntervel = 10;
            CFNumberRef frameIntervalRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &frameIntervel);
            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_MaxKeyFrameInterval, frameIntervalRef);
            
            //设置期望帧率
            int fps = 10;
            CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fps);
            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
            
            //设置码率
//            int bitRate = 1200 * 1000;
//            CFNumberRef bitRateRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitRate);
//            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_AverageBitRate, &bitRateRef);
            
//            int bigRateLimit = 720 * 1280 * 3 * 4;
//            CFNumberRef bitRateLimitRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bigRateLimit);
//            VTSessionSetProperty(sessionRef, kVTCompressionPropertyKey_DataRateLimits, bitRateLimitRef);
            
            //准备开始编码
            VTCompressionSessionPrepareToEncodeFrames(sessionRef);
            
            self.encodeSessionRef = sessionRef;
            
        }
        
        bNeedCreateComporessSession = NO;
    }
    

}

//视频采集，滤镜处理，编码都有了，就差推流
void didCompressH264(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer){
    
    BOOL isKeyFrame = !CFDictionaryContainsKey((CFDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0) , kCMSampleAttachmentKey_NotSync);
    //如果是关键帧就尝试读取pps和sps，没有不写入，反正有就
    if (isKeyFrame) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        size_t sparameterSetSize,sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0);
        if(statusCode == noErr){
            size_t pparameterSetSize,pparameterSetCount;
            const uint8_t *pparameterSet;
            
            OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize,&pparameterSetCount,0);
            if(statusCode == noErr){
                //Found pps & sps
                NSData *sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
                NSData *pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];
                
                YHGpuProcessor *processor = (__bridge YHGpuProcessor *)outputCallbackRefCon;
                [processor gotSpsPps:sps pps:pps];
            }
        }
    }
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length,totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if(statusCodeRet == noErr){
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;  //返回的nalu数据前4个字节是大端模式的帧长度length
        //循环获取nalu的数据
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            uint32_t NALUnitLength = 0;
            //读取一单元长度的nalu
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
            //从大端模式转换为系统端模式
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
            //获取nalu数据
            NSData *data = [[NSData alloc]initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength) length:NALUnitLength];
            //将nalu数据写入到文件
            YHGpuProcessor *processor = (__bridge YHGpuProcessor *)outputCallbackRefCon;
            [processor gotEncodedData:data isKeyFrame:isKeyFrame];
            //读取下一个nalu 一次回调可能包含多个nalu数据
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
    }
    
}


- (void)gotSpsPps:(NSData *)sps pps:(NSData *)pps{
    const char bytes[] = "\x00\x00\x00\x01";
    size_t length = (sizeof bytes) - 1;
    NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
    [self.fileHandle writeData:ByteHeader];
    [self.fileHandle writeData:sps];
    [self.fileHandle writeData:ByteHeader];
    [self.fileHandle writeData:pps];
}

- (void)gotEncodedData:(NSData*)data isKeyFrame:(BOOL)isKeyFrame{
    const char bytes[] = "\x00\x00\x00\x01";
    size_t length = (sizeof bytes) - 1;
    NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
    [self.fileHandle writeData:ByteHeader];
    [self.fileHandle writeData:data];
}


- (UIImage*)uiImageFromPixelBuffer:(CVPixelBufferRef)p {
    CIImage* ciImage = [CIImage imageWithCVPixelBuffer:p];
    
    CIContext* context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @(YES)}];
    
    CGRect rect = CGRectMake(0, 0, CVPixelBufferGetWidth(p), CVPixelBufferGetHeight(p));
    CGImageRef videoImage = [context createCGImage:ciImage fromRect:rect];
    
    UIImage* image = [UIImage imageWithCGImage:videoImage];
    CGImageRelease(videoImage);
    
    return image;
}

- (NSFileHandle*)fileHandle{
    if(!_fileHandle){
        NSArray *paths= NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentDirectory = [paths firstObject];
        NSString *filePath = [documentDirectory stringByAppendingPathComponent:@"h264.data"];
        
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
        
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    }
    return _fileHandle;
}

@end
