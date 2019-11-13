//
//  ViewController.m
//  GPUImageDemo
//
//  Created by 彭依汉 on 2019/8/29.
//  Copyright © 2019 彭依汉. All rights reserved.
//

#import "ViewController.h"
#import <Masonry.h>
#import <GPUImage.h>
#import <AVFoundation/AVFoundation.h>
#import "YHGpuProcessor.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AudioToolbox/AudioToolbox.h>

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureAudioDataOutputSampleBufferDelegate>

@property (weak, nonatomic) IBOutlet GPUImageView *imageView;

 //存储PCM裸数据
@property (assign, nonatomic) char* pcmBuffer;
@property (assign, nonatomic) unsigned long pcmBufferSize;

//存储AAC数据
@property (assign, nonatomic) char* aacBuffer;
@property (assign, nonatomic) unsigned long aacBufferSize;

@property (strong, nonatomic) AVCaptureSession *captureSession;

@property (strong, nonatomic) AVCaptureDevice *captureDevice;

@property (strong, nonatomic) AVCaptureDeviceInput *videoInput;

@property (strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;

@property (strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;

@property (strong, nonatomic) dispatch_queue_t captureQueue;

@property (strong, nonatomic) dispatch_queue_t aacEncoderQueue;

@property (strong, nonatomic) dispatch_queue_t dispatchQueue;

@property (strong, nonatomic) YHGpuProcessor *gpuProcessor;

@property (assign, nonatomic) AudioConverterRef audioConverter;

@property (strong, nonatomic) NSFileHandle *fileHandle;

@end

@implementation ViewController

#pragma mark ----------
#pragma mark ---------- life cycle ------------


- (void)viewDidLoad {
    [super viewDidLoad];

    _audioConverter = NULL;
    _pcmBufferSize = 0;
    _pcmBuffer = NULL;
    _aacBufferSize = 1024;
    _aacBuffer = malloc(_aacBufferSize * sizeof(uint8_t));
    memset(_aacBuffer, 0, _aacBufferSize);
    
    [self configCamera];
    [self.gpuProcessor createCompressSessionIfNeed];
}

- (void)captureSessionRunTimeError:(NSNotification *)notification{
    NSLog(@"%@",notification);
}

- (void)configCamera{
    [self.captureSession beginConfiguration];
    NSError *error = nil;
    
    AVCaptureDeviceInput *newVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:self.captureDevice error:&error];
    if(newVideoInput && [self.captureSession canAddInput:newVideoInput]){
        [self.captureSession addInput:newVideoInput];
        self.videoInput = newVideoInput;
    }
    //视频输出
    self.videoOutput = [[AVCaptureVideoDataOutput alloc]init];
    [self.videoOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    if([self.captureSession canAddOutput:self.videoOutput]){
        [self.captureSession addOutput:self.videoOutput];
    }
    
    AVCaptureConnection *videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    [videoConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    
    //音频采集输入端
    AVCaptureDevice *audioDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] lastObject];
    AVCaptureDeviceInput *audioDeviceInput = [[AVCaptureDeviceInput alloc]initWithDevice:audioDevice error:nil];
    if(audioDeviceInput && [self.captureSession canAddInput:audioDeviceInput]){
        [self.captureSession addInput:audioDeviceInput];
    }
    
    //音频数据输出端
    self.audioOutput = [[AVCaptureAudioDataOutput alloc]init];
    if([self.captureSession canAddOutput:self.audioOutput]){
        [self.captureSession addOutput:self.audioOutput];
    }
    [self.audioOutput setSampleBufferDelegate:self queue:self.captureQueue];
    
    if([self.captureDevice lockForConfiguration:NULL]){
        
        if(self.captureDevice.isLowLightBoostSupported){
            self.captureDevice.automaticallyEnablesLowLightBoostWhenAvailable = YES;
        }
        
        self.captureDevice.subjectAreaChangeMonitoringEnabled = YES;
        
        if (self.captureDevice.isFocusPointOfInterestSupported) {
            [self.captureDevice setFocusPointOfInterest:CGPointMake(0.5, 0.5)];
            
            if ([self.captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                [self.captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
            }
            else if([self.captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]){
                [self.captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
            }
        }
        
        if (self.captureDevice.isExposurePointOfInterestSupported) {
            [self.captureDevice setExposurePointOfInterest:CGPointMake(0.5, 0.5)];
            
            if ([self.captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                [self.captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
            }else if([self.captureDevice isExposureModeSupported:AVCaptureExposureModeAutoExpose]){
                [self.captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
            }
        }
        
        [self.captureDevice unlockForConfiguration];
    }
    
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
          self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
    }
    
    [self.captureSession commitConfiguration];
}

//AudioStreamBasicDescription是输出流的结构体描述
//配置好outAudioSteamBasicDescription 后
//根据AudioClassDescription（编码器）
//调用AudioConverterNewSpecific 创建转换器
- (void)setupEncoderFromSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    
    //输入
    AudioStreamBasicDescription inAudioSteamBasicDescription = *CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer));
    
    
    //初始化输出流的结构体描述为0，很重要
    AudioStreamBasicDescription outAudioSteamBasicDescription = {0};
    //音频流，在正常播放情况下的帧率。如果是压缩的格式，这个属性表示解压缩后的帧率。帧率不能为0
    outAudioSteamBasicDescription.mSampleRate = inAudioSteamBasicDescription.mSampleRate;
    //设置编码格式
    outAudioSteamBasicDescription.mFormatID = kAudioFormatMPEG4AAC;
    //无损编码，0表示没有
    outAudioSteamBasicDescription.mFormatFlags = kMPEG4Object_AAC_LC;
    //每一个packet的音视频数据大小。如果设置动态大小则设置为0，动态大小的格式，需要用AudioStreamPacketDesription来确定每个packet的大小
    outAudioSteamBasicDescription.mBytesPerPacket = 0;
    //每个packet的帧数。如果是未压缩的音频数据，值是1。动态帧率格式，这个值是较大的固定数字，比如说AAC的1024。如果是动态大小帧数（比如Ogg格式）设置为0.
    outAudioSteamBasicDescription.mFramesPerPacket = 1024;
    //每帧的大小。每一帧的起始点到下一帧的起始点。如果是压缩格式，设置为0.
    outAudioSteamBasicDescription.mBytesPerFrame = 0;
    //声道数
    outAudioSteamBasicDescription.mChannelsPerFrame = 1;
    //压缩格式设置为0
    outAudioSteamBasicDescription.mBitsPerChannel = 0;
    //8字节对齐，填0
    outAudioSteamBasicDescription.mReserved = 0;
    //获得编码器
    AudioClassDescription *description = [self getAudioClassDescriptionWithType:kAudioFormatMPEG4AAC fromManufacturer:kAppleSoftwareAudioCodecManufacturer];
    OSStatus status = AudioConverterNewSpecific(&inAudioSteamBasicDescription, &outAudioSteamBasicDescription, 1, description, &_audioConverter);
    if (status != 0) {
        NSLog(@"setup converter: %d",(int)status);
    }
}

- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type fromManufacturer:(UInt32)manufacturer{
    static AudioClassDescription desc;
    UInt32 encoderSpecifier = type;
    OSStatus st;
    
    UInt32 size;
    //拿到音频编码的格式大小
    st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size);
    
    if(st){
        NSLog(@"error getting audio format propery info: %d", (int)(st));
        return nil;
    }
    //一共有count这么多个编码的格式
    unsigned int count = size / sizeof(AudioClassDescription);
    
    //获取编码器数组
    AudioClassDescription descriptions[count];
    st = AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, descriptions);
    if(st){
        NSLog(@"error getting audio format propery: %d", (int)(st));
        return nil;
    }
    for (unsigned int i = 0; i < count; i++) {
        if((type == descriptions[i].mSubType) && (manufacturer == descriptions[i].mManufacturer)){
            memcpy(&desc, &(descriptions[i]), sizeof(desc));
            return &desc;
        }
    }
    return nil;
}


#pragma mark ----------
#pragma mark ---------- event && response ------------
- (IBAction)startCapture:(id)sender {
    if(!self.captureSession.isRunning){
        [self.captureSession startRunning];
    }
}

- (IBAction)stopCapture:(id)sender {
    if(self.captureSession.isRunning){
        [self.captureSession stopRunning];
    }
    
}

#pragma mark ----------
#pragma mark ---------- AVCaptureVideoDataOutputSampleBufferDelegate ------------
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection{
    
    if(captureOutput == self.videoOutput){        //处理视频数据
        dispatch_sync(self.dispatchQueue, ^{
            [self.gpuProcessor process:sampleBuffer];
        });
    } else if(captureOutput == self.audioOutput){ //处理音频数据
        dispatch_sync(self.dispatchQueue, ^{
            [self processAudioBuffer:sampleBuffer];
        });
    }
}

//处理音频数据
- (void)processAudioBuffer:(CMSampleBufferRef)sampleBuffer{
    CFRetain(sampleBuffer);
    dispatch_async(self.aacEncoderQueue, ^{
        if(!_audioConverter){
            [self setupEncoderFromSampleBuffer:sampleBuffer];
        }
        
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        CFRetain(blockBuffer);
        
        //这里拿到pcmBuffer指针和pcmBufferSize大小
        OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &_pcmBufferSize, &_pcmBuffer);
        if(status == kCMBlockBufferNoErr){
            
            memset(_aacBuffer, 0, _aacBufferSize);
            
            AudioBufferList outAudioBufferList = {0};
            outAudioBufferList.mNumberBuffers = 1;
            outAudioBufferList.mBuffers[0].mNumberChannels = 1;
            outAudioBufferList.mBuffers[0].mDataByteSize = (int)_aacBufferSize;
            outAudioBufferList.mBuffers[0].mData = _aacBuffer;
            
            AudioStreamPacketDescription *outPacketDescription = NULL;
            UInt32 ioOutputDataPacketSize = 1;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, inInputDataProc, (__bridge void *)(self), &ioOutputDataPacketSize, &outAudioBufferList, outPacketDescription);
            NSData *rawAAC;
            if(status == 0){
                rawAAC = [NSData dataWithBytes:outAudioBufferList.mBuffers[0].mData length:outAudioBufferList.mBuffers[0].mDataByteSize];
                NSData *adtsHeader = [self adtsDataForPacketLength:rawAAC.length];
                NSMutableData *fullData = [NSMutableData dataWithData:adtsHeader];
                [fullData appendData:rawAAC];
                rawAAC = fullData;
                
                [self.fileHandle writeData:rawAAC];
                NSLog(@"AAC Success");
            }
            
            CFRelease(sampleBuffer);
            CFRelease(blockBuffer);
        }
  
    });
}

- (NSData*) adtsDataForPacketLength:(NSUInteger)packetLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = 1;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + packetLength;
    // fill in ADTS data
    packet[0] = (char)0xFF; // 11111111     = syncword
    packet[1] = (char)0xF9; // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

OSStatus inInputDataProc(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    ViewController *encoder = (__bridge ViewController *)(inUserData);
    UInt32 requestedPackets = *ioNumberDataPackets;
    
    size_t copiedSamples = [encoder copyPCMSamplesIntoBuffer:ioData];
    if (copiedSamples < requestedPackets) {
        //PCM 缓冲区还没满
        *ioNumberDataPackets = 0;
        return -1;
    }
    *ioNumberDataPackets = 1;
    return noErr;
}

 
- (size_t) copyPCMSamplesIntoBuffer:(AudioBufferList*)ioData {
    size_t originalBufferSize = _pcmBufferSize;
    if (!originalBufferSize) {
        return 0;
    }
    ioData->mBuffers[0].mData = _pcmBuffer;
    ioData->mBuffers[0].mDataByteSize = (int)_pcmBufferSize;
    _pcmBuffer = NULL;
    _pcmBufferSize = 0;
    return originalBufferSize;
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

- (uint8_t *)convertVideoSampleBufferToYuvData:(CMSampleBufferRef)videoSample{
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(videoSample);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    //获得高、宽确定需要申请的存储空间
    size_t pixelWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t pixelHeight = CVPixelBufferGetHeight(pixelBuffer);
    size_t y_size = pixelWidth * pixelHeight;
    size_t uv_size = y_size/2;
    uint8_t *yuv_frame = malloc(uv_size + y_size);
    //获得Y平面的起始地址
    uint8_t *y_frame = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    memcpy(yuv_frame, y_frame, y_size);
    //获得UV平面的起始地址
    uint8_t *uv_frame = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    memcpy(yuv_frame+y_size, uv_frame, uv_size);
    return yuv_frame;
    //return [NSData dataWithBytesNoCopy:yuv_frame length:uv_size + y_size]/;
}


#pragma mark ----------
#pragma mark ---------- setter && getter ------------
- (AVCaptureSession *)captureSession{
    if(!_captureSession){
        _captureSession = [[AVCaptureSession alloc]init];
        _captureSession.usesApplicationAudioSession = NO;
    }
    return _captureSession;
}


- (AVCaptureDevice *)captureDevice{
    if(!_captureDevice){
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for(AVCaptureDevice *device in devices){
            if([device position] == AVCaptureDevicePositionFront){
                _captureDevice = device;
                break;
            }
        }
    }
    return _captureDevice;
}

- (dispatch_queue_t)captureQueue{
    if (!_captureQueue) {
        _captureQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    return _captureQueue;
}


- (dispatch_queue_t)dispatchQueue{
    if(!_dispatchQueue){
        _dispatchQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    return _dispatchQueue;
}

- (dispatch_queue_t)aacEncoderQueue{
    if(!_aacEncoderQueue){
        _aacEncoderQueue = dispatch_queue_create("me.yohen.aacencoder", DISPATCH_QUEUE_SERIAL);
    }
    return _aacEncoderQueue;
}

//传入GPUImageView用于滤镜处理后展示
- (YHGpuProcessor *)gpuProcessor{
    if(!_gpuProcessor){
        _gpuProcessor = [[YHGpuProcessor alloc]initWithGpuImageView:self.imageView];
    }
    return _gpuProcessor;
}


- (NSFileHandle*)fileHandle{
    if(!_fileHandle){
        NSArray *paths= NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentDirectory = [paths firstObject];
        NSString *filePath = [documentDirectory stringByAppendingPathComponent:@"aac.data"];
        
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
        
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    }
    return _fileHandle;
}


@end
