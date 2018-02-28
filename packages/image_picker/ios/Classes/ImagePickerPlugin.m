// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@import UIKit;

#import "ImagePickerPlugin.h"

@interface FLTImagePickerPlugin ()<UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

static const int SOURCE_ASK_USER = 0;
static const int SOURCE_CAMERA = 1;
static const int SOURCE_GALLERY = 2;

@implementation FLTImagePickerPlugin {
  FlutterResult _result;
  NSDictionary *_arguments;
  UIImagePickerController *_imagePickerController;
  UIViewController *_viewController;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"image_picker"
                                  binaryMessenger:[registrar messenger]];
  UIViewController *viewController =
      [UIApplication sharedApplication].delegate.window.rootViewController;
  FLTImagePickerPlugin *instance =
      [[FLTImagePickerPlugin alloc] initWithViewController:viewController];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithViewController:(UIViewController *)viewController {
  self = [super init];
  if (self) {
    _viewController = viewController;
    _imagePickerController = [[UIImagePickerController alloc] init];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (_result) {
    _result([FlutterError errorWithCode:@"multiple_request"
                                message:@"Cancelled by a second request"
                                details:nil]);
    _result = nil;
  }

  if ([@"pickImage" isEqualToString:call.method]) {
    _imagePickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
    _imagePickerController.delegate = self;

    _result = result;
    _arguments = call.arguments;

    int imageSource = [[_arguments objectForKey:@"source"] intValue];

    switch (imageSource) {
      case SOURCE_ASK_USER:
        [self showImageSourceSelector];
        break;
      case SOURCE_CAMERA:
        [self showCamera];
        break;
      case SOURCE_GALLERY:
        [self showPhotoLibrary];
        break;
      default:
        result([FlutterError errorWithCode:@"invalid_source"
                                   message:@"Invalid image source."
                                   details:nil]);
        break;
    }
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)showImageSourceSelector {
  UIAlertControllerStyle style = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
                                     ? UIAlertControllerStyleAlert
                                     : UIAlertControllerStyleActionSheet;

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:style];
  UIAlertAction *camera = [UIAlertAction actionWithTitle:@"Take Photo"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
                                                   [self showCamera];
                                                 }];
  UIAlertAction *library = [UIAlertAction actionWithTitle:@"Choose Photo"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
                                                    [self showPhotoLibrary];
                                                  }];
  UIAlertAction *cancel =
      [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
  [alert addAction:camera];
  [alert addAction:library];
  [alert addAction:cancel];
  [_viewController presentViewController:alert animated:YES completion:nil];
}

- (void)showCamera {
  // Camera is not available on simulators
  if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    _imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
    [_viewController presentViewController:_imagePickerController animated:YES completion:nil];
  } else {
    [[[UIAlertView alloc] initWithTitle:@"Error"
                                message:@"Camera not available."
                               delegate:nil
                      cancelButtonTitle:@"OK"
                      otherButtonTitles:nil] show];
  }
}

- (void)showPhotoLibrary {
  // No need to check if SourceType is available. It always is.
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  [_viewController presentViewController:_imagePickerController animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info {
  [_imagePickerController dismissViewControllerAnimated:YES completion:nil];
  UIImage *image = [info objectForKey:UIImagePickerControllerEditedImage];
  if (image == nil) {
    image = [info objectForKey:UIImagePickerControllerOriginalImage];
  }
  image = [self normalizedImage:image];

  NSNumber *maxWidth = [_arguments objectForKey:@"maxWidth"];
  NSNumber *maxHeight = [_arguments objectForKey:@"maxHeight"];
  CGFloat quality = 1.0;
  if ([_arguments objectForKey:@"quality"] != (id)[NSNull null]) quality = (CGFloat) [[_arguments objectForKey:@"quality"] floatValue];

  if (maxWidth != (id)[NSNull null] || maxHeight != (id)[NSNull null]) {
    image = [self scaledImage:image maxWidth:maxWidth maxHeight:maxHeight];
  }
    

    NSData *data = UIImageJPEGRepresentation(image, quality);
  NSString *tmpDirectory = NSTemporaryDirectory();
  NSString *guid = [[NSProcessInfo processInfo] globallyUniqueString];
  // TODO(jackson): Using the cache directory might be better than temporary
  // directory.
  NSString *tmpFile = [NSString stringWithFormat:@"image_picker_%@.jpg", guid];
  NSString *tmpPath = [tmpDirectory stringByAppendingPathComponent:tmpFile];
  if ([[NSFileManager defaultManager] createFileAtPath:tmpPath contents:data attributes:nil]) {
    _result(tmpPath);
  } else {
    _result([FlutterError errorWithCode:@"create_error"
                                message:@"Temporary file could not be created"
                                details:nil]);
  }
  _result = nil;
  _arguments = nil;
}

// The way we save images to the tmp dir currently throws away all EXIF data
// (including the orientation of the image). That means, pics taken in portrait
// will not be orientated correctly as is. To avoid that, we rotate the actual
// image data.
// TODO(goderbauer): investigate how to preserve EXIF data.
- (UIImage *)normalizedImage:(UIImage *)image {
  if (image.imageOrientation == UIImageOrientationUp) return image;

  UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
  [image drawInRect:(CGRect){0, 0, image.size}];
  UIImage *normalizedImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return normalizedImage;
}

- (UIImage *)scaledImage:(UIImage *)image
                maxWidth:(NSNumber *)maxWidth
               maxHeight:(NSNumber *)maxHeight {
  double originalWidth = image.size.width;
  double originalHeight = image.size.height;

  bool hasMaxWidth = maxWidth != (id)[NSNull null];
  bool hasMaxHeight = maxHeight != (id)[NSNull null];

  double width = hasMaxWidth ? MIN([maxWidth doubleValue], originalWidth) : originalWidth;
  double height = hasMaxHeight ? MIN([maxHeight doubleValue], originalHeight) : originalHeight;

  bool shouldDownscaleWidth = hasMaxWidth && [maxWidth doubleValue] < originalWidth;
  bool shouldDownscaleHeight = hasMaxHeight && [maxHeight doubleValue] < originalHeight;
  bool shouldDownscale = shouldDownscaleWidth || shouldDownscaleHeight;

  if (shouldDownscale) {
    double downscaledWidth = (height / originalHeight) * originalWidth;
    double downscaledHeight = (width / originalWidth) * originalHeight;

    if (width < height) {
      if (!hasMaxWidth) {
        width = downscaledWidth;
      } else {
        height = downscaledHeight;
      }
    } else if (height < width) {
      if (!hasMaxHeight) {
        height = downscaledHeight;
      } else {
        width = downscaledWidth;
      }
    } else {
      if (originalWidth < originalHeight) {
        width = downscaledWidth;
      } else if (originalHeight < originalWidth) {
        height = downscaledHeight;
      }
    }
  }

  UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, 1.0);
  [image drawInRect:CGRectMake(0, 0, width, height)];

  UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();

  return scaledImage;
}

@end
