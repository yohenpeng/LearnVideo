//
//  YHGpuProcessor.h
//  GPUImageDemo
//
//  Created by 彭依汉 on 2019/9/19.
//  Copyright © 2019 彭依汉. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <GPUImage.h>

NS_ASSUME_NONNULL_BEGIN

@interface YHGpuProcessor : GPUImageOutput

- (instancetype)initWithGpuImageView:(GPUImageView *)imageView;

- (void)process:(CMSampleBufferRef)sampleBuffer;

@property (assign, nonatomic) AudioConverterRef audioConverter;

@end

NS_ASSUME_NONNULL_END
