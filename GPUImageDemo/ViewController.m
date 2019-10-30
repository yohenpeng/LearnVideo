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

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureAudioDataOutputSampleBufferDelegate>

@property (weak, nonatomic) IBOutlet GPUImageView *imageView;

@property (strong, nonatomic) AVCaptureSession *captureSession;

@property (strong, nonatomic) AVCaptureDevice *captureDevice;

@property (strong, nonatomic) AVCaptureDeviceInput *videoInput;

@property (strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;

@property (strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;

@property (strong, nonatomic) dispatch_queue_t videoQueue;

@property (strong, nonatomic) YHGpuProcessor *gpuProcessor;

@property (assign, nonatomic) AudioConverterRef audioConverter;

@end

@implementation ViewController

#pragma mark ----------
#pragma mark ---------- life cycle ------------
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    [self configCamera];
    
    NSLog(@"count:%ld",[self countStep:5]);
}

- (NSInteger)countStep:(NSInteger)count{
    if(count == 1){
        return 1;
    }
    if (count == 2){
        return 2;
    }
    return [self countStep:count-1] + [self countStep:count -2];
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
    [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
    if([self.captureSession canAddOutput:self.videoOutput]){
        [self.captureSession addOutput:self.videoOutput];
    }
    //音频输出
    self.audioOutput = [[AVCaptureAudioDataOutput alloc]init];
    if([self.captureSession canAddOutput:self.audioOutput]){
        [self.captureSession addOutput:self.audioOutput];
    }
    [self.audioOutput setSampleBufferDelegate:self queue:self.videoQueue];
    
    AVCaptureConnection *videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    [videoConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    
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

- (void)setupEncoderFromSampleBuffer:(CMSampleBufferRef)sampleBuffer{
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
    //软编
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
        if((type == descriptions[i].mSubType) && (manufacturer == descriptions[i].mSubType)){
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
//    CVPixelBufferRef ref = CMSampleBufferGetImageBuffer(sampleBuffer);
//    UIImage *image = [self uiImageFromPixelBuffer:ref];
    [self.gpuProcessor process:sampleBuffer];
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

- (dispatch_queue_t)videoQueue{
    if(!_videoQueue){
        _videoQueue = dispatch_queue_create("me.yohen.videocapture", DISPATCH_QUEUE_SERIAL);
    }
    return _videoQueue;
}

//传入GPUImageView用于滤镜处理后展示
- (YHGpuProcessor *)gpuProcessor{
    if(!_gpuProcessor){
        _gpuProcessor = [[YHGpuProcessor alloc]initWithGpuImageView:self.imageView];
    }
    return _gpuProcessor;
}



@end
