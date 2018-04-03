/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 * (c) Jamie Pinkham
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

/**
 整体目录结构：
 SDWebImage
 | - SDWebImageCompat处理不同平台（iOS，TV，OS，Watch）宏，以及根据文件名@ 2x，@ 3x进行图片处理和缩放
 | - SDWebImageOperation.h添加取消委托
 + - Cache
 | --- SDImageCache 主要处理缓存逻辑，重要集中在：NSCache（内存），磁盘读写，清理旧文件
 | --- SDImageCacheConfig 配置缓存参数：是否压缩，iCloud，InMemory，ReadingOption，时间和CacheSize
 + - Downloader
 | --- SDWebImageDownloaderOperation 主要提供下载的操作
 | --- SDWebImageDownloader 提供下载管理入口
 + - Utils
 | --- SDWebImageManager提供外层管理缓存和下载入口
 | --- SDWebImagePrefetcher预处理获取Image，主要应用预加载的地方
 + - Categories
 | --- NSData+ImageContentType提供类型判断和ImageIO类型转换
 | --- UIImage+GIF数据转UIImage（GIF）扩展
 | --- UIImage+MultiFormat 提供BitMap或者未知类型的Data转UIImage扩展
 | --- UIImage+WebP 数据转WebP扩展
 | --- UIImage+ForceDecode 解压操作
 | ---UIView+WebCacheOperation 提供顶层关于取消和下载记录的扩展
 + - Decoder
 | --- SDWebImageCodersManager整体打码机的入口，提供是否可编码器和编码器转发
 | --- SDWebImageCoder 主要说明编码器委派实现需要的接口
 | --- SDWebImageImageIOCoder PNG / JPEG编码的和解压操作
 | --- SDWebImageGIFCoder GIF的编码器操作
 | --- SDWebImageWebPCoder WebP的编码器操作
 | --- SDWebImageFrame 辅助类，主要在GIF等动态图使用
 | --- SDWebImageCoderHelper 辅助类，包括方向，Gif图合成等
 */
//https://www.jianshu.com/p/fd984fd8bd5d
//参考 https://www.jianshu.com/p/06f0265c22eb
#import <TargetConditionals.h>
//https://www.jianshu.com/p/1d2e4d822732
#ifdef __OBJC_GC__
    #error SDWebImage does not support Objective-C Garbage Collection
#endif

// Apple's defines from TargetConditionals.h are a bit weird.
// Seems like TARGET_OS_MAC is always defined (on all platforms).
// To determine if we are running on OSX, we can only rely on TARGET_OS_IPHONE=0 and all the other platforms
//判断是否MACOS系统
#if !TARGET_OS_IPHONE && !TARGET_OS_IOS && !TARGET_OS_TV && !TARGET_OS_WATCH
    #define SD_MAC 1
#else
    #define SD_MAC 0
#endif

// iOS and tvOS are very similar, UIKit exists on both platforms
// Note: watchOS also has UIKit, but it's very limited
//watchOS使用UIKit受限
#if TARGET_OS_IOS || TARGET_OS_TV
    #define SD_UIKIT 1
#else
    #define SD_UIKIT 0
#endif

#if TARGET_OS_IOS
    #define SD_IOS 1
#else
    #define SD_IOS 0
#endif

#if TARGET_OS_TV
    #define SD_TV 1
#else
    #define SD_TV 0
#endif

#if TARGET_OS_WATCH
    #define SD_WATCH 1
#else
    #define SD_WATCH 0
#endif

//平台兼容
#if SD_MAC
    #import <AppKit/AppKit.h>
    #ifndef UIImage
        #define UIImage NSImage  //MAC系统 NSImage替换UIImage
    #endif
    #ifndef UIImageView
        #define UIImageView NSImageView //MAC系统 NSImageView替换UIImageView
    #endif
    #ifndef UIView
        #define UIView NSView  //MAC系统 NSView替换UIView
    #endif
#else
    #if __IPHONE_OS_VERSION_MIN_REQUIRED != 20000 && __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_5_0
        #error SDWebImage doesn't support Deployment Target version < 5.0
    #endif

    #if SD_UIKIT
        #import <UIKit/UIKit.h>
    #endif
    #if SD_WATCH
        #import <WatchKit/WatchKit.h>
    #endif
#endif

#ifndef NS_ENUM
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#endif

#ifndef NS_OPTIONS
#define NS_OPTIONS(_type, _name) enum _name : _type _name; enum _name : _type
#endif

FOUNDATION_EXPORT UIImage *SDScaledImageForKey(NSString *key, UIImage *image);

typedef void(^SDWebImageNoParamsBlock)(void);

FOUNDATION_EXPORT NSString *const SDWebImageErrorDomain;
//dispatch_queue_get_label 获取队列名字  strcmp（1，1）=0
//dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)获取当前队列名字，如果是同一队列
//当前队列中执行block，否则在queue中异步执行block
#ifndef dispatch_queue_async_safe
#define dispatch_queue_async_safe(queue, block)\
    if (strcmp(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL), dispatch_queue_get_label(queue)) == 0) {\
        block();\
    } else {\
        dispatch_async(queue, block);\
    }
#endif

//确保在主线程中调用block
#ifndef dispatch_main_async_safe
#define dispatch_main_async_safe(block) dispatch_queue_async_safe(dispatch_get_main_queue(), block)
#endif
