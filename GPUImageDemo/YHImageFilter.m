//
//  YHImageFilter.m
//  GPUImageDemo
//
//  Created by 彭依汉 on 2019/9/26.
//  Copyright © 2019 彭依汉. All rights reserved.
//

#import "YHImageFilter.h"

NSString *const kCoverImageFragmentShaderString = SHADER_STRING
(
  varying highp vec2 textureCoordinate;
  
  uniform sampler2D inputImageTexture;
  
  void main()
  {
    highp vec4 FragColor = texture2D(inputImageTexture, textureCoordinate);
    gl_FragColor = vec4(FragColor.x,FragColor.y,1.0-FragColor.z,1.0);
  }
 );

@interface YHImageFilter (){

}

@end

@implementation YHImageFilter

- (instancetype)init{
    self = [self initWithFragmentShaderFromString:kCoverImageFragmentShaderString];
    return self;
}

@end
