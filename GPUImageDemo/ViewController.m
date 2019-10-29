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

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property (weak, nonatomic) IBOutlet GPUImageView *imageView;

@property (strong, nonatomic) AVCaptureSession *captureSession;

@property (strong, nonatomic) AVCaptureDevice *captureDevice;

@property (strong, nonatomic) AVCaptureDeviceInput *videoInput;

@property (strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;


@property (strong, nonatomic) dispatch_queue_t videoQueue;

@property (strong, nonatomic) YHGpuProcessor *gpuProcessor;

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
    
    self.videoOutput = [[AVCaptureVideoDataOutput alloc]init];
    [self.videoOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
    if([self.captureSession canAddOutput:self.videoOutput]){
        [self.captureSession addOutput:self.videoOutput];
    }
    
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

//传入GPUImageView用于
- (YHGpuProcessor *)gpuProcessor{
    if(!_gpuProcessor){
        _gpuProcessor = [[YHGpuProcessor alloc]initWithGpuImageView:self.imageView];
    }
    return _gpuProcessor;
}



@end
