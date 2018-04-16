/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"

#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

@interface SDWebImageDownloadToken ()
/**
 SDWebImageDownloaderOperationInterface协议
 //初始化
 - (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
 inSession:(nullable NSURLSession *)session
 options:(SDWebImageDownloaderOptions)options;
 //添加回调
 - (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;
 //是否需要解压图片
 - (BOOL)shouldDecompressImages;
 - (void)setShouldDecompressImages:(BOOL)value;
 
 - (nullable NSURLCredential *)credential;
 //设置是否需要设置凭证
 - (void)setCredential:(nullable NSURLCredential *)value;
 //取消
 - (BOOL)cancel:(nullable id)token;

 
 */
@property (nonatomic, weak, nullable) NSOperation<SDWebImageDownloaderOperationInterface> *downloadOperation;

@end

@implementation SDWebImageDownloadToken

- (void)cancel {
    if (self.downloadOperation) {
        SDWebImageDownloadToken *cancelToken = self.downloadOperationCancelToken;
        if (cancelToken) {
            [self.downloadOperation cancel:cancelToken];
        }
    }
}

@end


@interface SDWebImageDownloader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>
//nonnull 不能为空
@property (strong, nonatomic, nonnull) NSOperationQueue *downloadQueue;//下载队列
//nullable 可以为空
@property (weak, nonatomic, nullable) NSOperation *lastAddedOperation;//最后加入Operation
@property (assign, nonatomic, nullable) Class operationClass;//自定义的操作类
@property (strong, nonatomic, nonnull) NSMutableDictionary<NSURL *, SDWebImageDownloaderOperation *> *URLOperations;//全局下载字典
@property (strong, nonatomic, nullable) SDHTTPHeadersMutableDictionary *HTTPHeaders;//HTTP请求头
@property (strong, nonatomic, nonnull) dispatch_semaphore_t operationsLock; // a lock to keep the access to `URLOperations` thread-safe
@property (strong, nonatomic, nonnull) dispatch_semaphore_t headersLock; // a lock to keep the access to `HTTPHeaders` thread-safe

// The session in which data tasks will run
@property (strong, nonatomic) NSURLSession *session;

@end

@implementation SDWebImageDownloader
/**
 //http://www.cocoachina.com/ios/20161012/17732.html
 + (void)load;
 对于加入运行期系统的类及分类，必定会调用此方法，且仅调用一次。
 
 iOS会在应用程序启动的时候调用load方法，在main函数之前调用
 
 执行子类的load方法前，会先执行所有超类的load方法，顺序为父类->子类->分类
 
 在load方法中使用其他类是不安全的，因为会调用其他类的load方法，而如果关系复杂的话，就无法判断出各个类的载入顺序，类只有初始化完成后，类实例才能进行正常使用
 
 load 方法不遵从继承规则，如果类本身没有实现load方法，那么系统就不会调用，不管父类有没有实现（跟下文的initialize有明显区别）
 
 尽可能的精简load方法，因为整个应用程序在执行load方法时会阻塞，即，程序会阻塞直到所有类的load方法执行完毕，才会继续
 
 load 方法中最常用的就是方法交换method swizzling
 */
/**
 + (void)initialize;
 在首次使用该类之前由运行期系统（非人为）调用，且仅调用一次
 
 惰性调用，只有当程序使用相关类时，才会调用
 
 运行期系统会确保initialize方法是在线程安全的环境中执行，即，只有执行initialize的那个线程可以操作类或类实例。其他线程都要先阻塞，等待initialize执行完
 
 如果类未实现initialize方法，而其超类实现了，那么会运行超类的实现代码，而且会运行两次（load 第5点）
 
 initialize 遵循继承规则
 
 初始化子类的的时候会先初始化父类，然后会调用父类的initialize方法，而子类没有覆写initialize方法，因此会再次调用父类的实现方法
 
 鉴于此，initialize方法实现如下：
 
 + (void)initialize {
 if (self == [People class]) {
 NSLog(@"%@ initialize", self);
 }
 }
 initialize方法也需要尽量精简，一般只应该用来设置内部数据，比如，某个全局状态无法在编译期初始化，可以放在initialize里面。
 
 static NSMutableArray *kSomeObjects;
 @implementation People
 + (void)initialize {
 if (self == [People class]) {
 kSomeObjects = [NSMutableArray new];
 }
 }
*/

+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    //runtime机制生成SDNetworkActivityIndicator类型实例
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        //runtime机制调用SDNetworkActivityIndicator类型方法sharedActivityIndicator生成实例
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop
        
        // Remove observer in case it was previously added.
        //移除Start，stop通知
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];
        //添加通知
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}
//单例
+ (nonnull instancetype)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    return [self initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
}

- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration {
    if ((self = [super init])) {
        //队列
        _operationClass = [SDWebImageDownloaderOperation class];
        _shouldDecompressImages = YES;//下载图片是否需要解压缩，默认yes
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        //并发数6
        _downloadQueue = [NSOperationQueue new];
        _downloadQueue.maxConcurrentOperationCount = 6;
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";
        _URLOperations = [NSMutableDictionary new];
#ifdef SD_WEBP
        _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
#else
        _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
#endif
        _operationsLock = dispatch_semaphore_create(1);
        _headersLock = dispatch_semaphore_create(1);
        _downloadTimeout = 15.0;//超时时间
        //新建session
        [self createNewSessionWithConfiguration:sessionConfiguration];
    }
    return self;
}

- (void)createNewSessionWithConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    //取消所有下载任务
    [self cancelAllDownloads];
    
    if (self.session) {
        [self.session invalidateAndCancel];
    }
    
    sessionConfiguration.timeoutIntervalForRequest = self.downloadTimeout;

    /**
     *  Create the session for this task
     *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
     *  method calls and completion handler calls.
     */
    //创建下载NSURLSession
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                 delegate:self
                                            delegateQueue:nil];
}

- (void)invalidateSessionAndCancel:(BOOL)cancelPendingOperations {
    if (self == [SDWebImageDownloader sharedDownloader]) {
        return;
    }
    if (cancelPendingOperations) {
        [self.session invalidateAndCancel];
    } else {
        [self.session finishTasksAndInvalidate];
    }
}

- (void)dealloc {
    [self.session invalidateAndCancel];
    self.session = nil;

    [self.downloadQueue cancelAllOperations];
}

- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field {
    //dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);信号量 锁住
    LOCK(self.headersLock);
    if (value) {
        //设置
        self.HTTPHeaders[field] = value;
    } else {
        [self.HTTPHeaders removeObjectForKey:field];
    }
    //dispatch_semaphore_signal(lock) 解锁
    UNLOCK(self.headersLock);
}

- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field {
    if (!field) {
        return nil;
    }
    return [[self allHTTPHeaderFields] objectForKey:field];
}

- (nonnull SDHTTPHeadersDictionary *)allHTTPHeaderFields {
    //dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);信号量 锁住
    LOCK(self.headersLock);
    SDHTTPHeadersDictionary *allHTTPHeaderFields = [self.HTTPHeaders copy];
    UNLOCK(self.headersLock);
    return allHTTPHeaderFields;
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;
}

- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;
}

- (NSURLSessionConfiguration *)sessionConfiguration {
    return self.session.configuration;
}

- (void)setOperationClass:(nullable Class)operationClass {
    if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperationInterface)]) {
        _operationClass = operationClass;
    } else {
        _operationClass = [SDWebImageDownloaderOperation class];
    }
}
#pragma mark - 核心方法

// 核心方法 返回SDWebImageDownloadToken，里面包含操作，操作标示，url，取消方法
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
    __weak SDWebImageDownloader *wself = self;
    
    return [self addProgressCallback:progressBlock completedBlock:completedBlock forURL:url createCallback:^SDWebImageDownloaderOperation *{
        //没有对应操作，创建操作
        __strong __typeof (wself) sself = wself;
        NSTimeInterval timeoutInterval = sself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
        //创建下载request及配置
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                    cachePolicy:cachePolicy
                                                                timeoutInterval:timeoutInterval];
        
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        request.HTTPShouldUsePipelining = YES;
        //headersFilter SDWebImageDownloaderHeadersFilterBlock 类回调
        if (sself.headersFilter) {
            request.allHTTPHeaderFields = sself.headersFilter(url, [sself allHTTPHeaderFields]);
        }
        else {
            request.allHTTPHeaderFields = [sself allHTTPHeaderFields];
        }
        //创建操作 SDWebImageDownloaderOperation
        SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
        //下载后是否需要解压搜
        operation.shouldDecompressImages = sself.shouldDecompressImages;
        //验证信息
        if (sself.urlCredential) {
            operation.credential = sself.urlCredential;
        } else if (sself.username && sself.password) {
            operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
        }
        //设置队列优先级
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        } else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }
        //先进后出，添加依赖，最后的依赖于新添加的任务完成
        if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [sself.lastAddedOperation addDependency:operation];
            sself.lastAddedOperation = operation;
        }
        //返回操作
        return operation;
    }];
}
//取消操作
- (void)cancel:(nullable SDWebImageDownloadToken *)token {
    NSURL *url = token.url;
    if (!url) {
        return;
    }
    //锁
    LOCK(self.operationsLock);
    //取出operation
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];
    if (operation) {
        BOOL canceled = [operation cancel:token.downloadOperationCancelToken];
        if (canceled) {
            [self.URLOperations removeObjectForKey:url];
        }
    }
    UNLOCK(self.operationsLock);
}
#pragma mark - 核心方法
- (nullable SDWebImageDownloadToken *)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock
                                           completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock
                                                   forURL:(nullable NSURL *)url
                                           createCallback:(SDWebImageDownloaderOperation *(^)(void))createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    //判空
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return nil;
    }
    //信号量  下载队列添加操作上锁
    LOCK(self.operationsLock);
    //self.URLOperations中获取下载操作  url为key
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];
    //新建SDWebImageDownloaderOperation
    if (!operation) {
        //没有对应操作，创建之
        /**
         //没有对应操作，创建操作
         __strong __typeof (wself) sself = wself;
         NSTimeInterval timeoutInterval = sself.downloadTimeout;
         if (timeoutInterval == 0.0) {
         timeoutInterval = 15.0;
         }
         
         // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
         NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
         //创建下载request及配置
         NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
         cachePolicy:cachePolicy
         timeoutInterval:timeoutInterval];
         
         request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
         request.HTTPShouldUsePipelining = YES;
         //headersFilter SDWebImageDownloaderHeadersFilterBlock 类回调
         if (sself.headersFilter) {
         request.allHTTPHeaderFields = sself.headersFilter(url, [sself allHTTPHeaderFields]);
         }
         else {
         request.allHTTPHeaderFields = [sself allHTTPHeaderFields];
         }
         //创建操作 SDWebImageDownloaderOperation
         SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
         //下载后是否需要解压搜
         operation.shouldDecompressImages = sself.shouldDecompressImages;
         //验证信息
         if (sself.urlCredential) {
         operation.credential = sself.urlCredential;
         } else if (sself.username && sself.password) {
         operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
         }
         //设置队列优先级
         if (options & SDWebImageDownloaderHighPriority) {
         operation.queuePriority = NSOperationQueuePriorityHigh;
         } else if (options & SDWebImageDownloaderLowPriority) {
         operation.queuePriority = NSOperationQueuePriorityLow;
         }
         //先进后出，添加依赖，最后的依赖于新添加的任务完成
         if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
         // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
         [sself.lastAddedOperation addDependency:operation];
         sself.lastAddedOperation = operation;
         }
         //返回操作
         return operation;

         */
        operation = createCallback();
        __weak typeof(self) wself = self;
        //操作完成回调
        operation.completionBlock = ^{
            __strong typeof(wself) sself = wself;
            if (!sself) {
                return;
            }
            //线程安全删除对应操作
            LOCK(sself.operationsLock);
            [sself.URLOperations removeObjectForKey:url];
            UNLOCK(sself.operationsLock);
        };
        //添加到全局操作字典  url作为键
        [self.URLOperations setObject:operation forKey:url];
        // Add operation to operation queue only after all configuration done according to Apple's doc.
        // `addOperation:` does not synchronously execute the `operation.completionBlock` so this will not cause deadlock.
        //下载队列添加操作
        [self.downloadQueue addOperation:operation];
    }
    UNLOCK(self.operationsLock);

    //给操作添加进度block和完成block，返回操作标示downloadOperationCancelToken
    //typedef void(^SDWebImageDownloaderProgressBlock)(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL);
    //typedef void(^SDWebImageDownloaderCompletedBlock)(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, BOOL finished);
    id downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];
    //生成SDWebImageDownloadToken用来管理操作
    SDWebImageDownloadToken *token = [SDWebImageDownloadToken new];
    //弱引用
    token.downloadOperation = operation;
    token.url = url;
    token.downloadOperationCancelToken = downloadOperationCancelToken;

    return token;
}

- (void)setSuspended:(BOOL)suspended {
    self.downloadQueue.suspended = suspended;
}

- (void)cancelAllDownloads {
    [self.downloadQueue cancelAllOperations];
}

#pragma mark Helper methods

- (SDWebImageDownloaderOperation *)operationWithTask:(NSURLSessionTask *)task {
    SDWebImageDownloaderOperation *returnOperation = nil;
    for (SDWebImageDownloaderOperation *operation in self.downloadQueue.operations) {
        if (operation.dataTask.taskIdentifier == task.taskIdentifier) {
            returnOperation = operation;
            break;
        }
    }
    return returnOperation;
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(NSURLSessionResponseAllow);
        }
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveData:data];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:willCacheResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(proposedResponse);
        }
    }
}

#pragma mark NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [dataOperation URLSession:session task:task didCompleteWithError:error];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)]) {
        [dataOperation URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(request);
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
        [dataOperation URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    }
}

@end
