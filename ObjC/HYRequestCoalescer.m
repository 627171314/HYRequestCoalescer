#import "HYRequestCoalescer.h"

@interface HYRequestCoalescer ()

@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, strong) NSMutableArray<HYCoalescerCallback> *callbacks;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, strong, nullable) id cachedResult;
@property (nonatomic, strong, nullable) NSDate *cacheTime;

@end

@implementation HYRequestCoalescer

- (instancetype)init {
    return [self initWithCacheTTL:0 callbackQueue:dispatch_get_main_queue()];
}

- (instancetype)initWithCacheTTL:(NSTimeInterval)cacheTTL
                   callbackQueue:(dispatch_queue_t)callbackQueue {
    self = [super init];
    if (self) {
        _cacheTTL = cacheTTL;
        _callbackQueue = callbackQueue;
        _lock = [[NSLock alloc] init];
        _callbacks = [NSMutableArray array];
        _generation = 0;
        _loading = NO;
    }
    return self;
}

- (BOOL)isLoading {
    [self.lock lock];
    BOOL result = self.loading;
    [self.lock unlock];
    return result;
}

#pragma mark - Public

- (void)requestWithExecute:(void (^)(HYCoalescerCallback))execute
                completion:(HYCoalescerCallback)completion {
    [self.lock lock];

    // 1. 检查缓存
    if (self.cacheTTL > 0 && self.cachedResult && self.cacheTime) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.cacheTime];
        if (elapsed < self.cacheTTL) {
            id cached = self.cachedResult;
            [self.lock unlock];
            dispatch_async(self.callbackQueue, ^{
                completion(cached, nil);
            });
            return;
        }
    }

    // 2. 加入等待队列
    [self.callbacks addObject:[completion copy]];

    // 3. 已有请求在飞，只排队
    if (self.loading) {
        [self.lock unlock];
        return;
    }

    // 4. 发起新请求
    self.loading = YES;
    NSUInteger currentGeneration = self.generation;
    [self.lock unlock];

    __weak typeof(self) weakSelf = self;
    execute(^(id _Nullable result, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf.lock lock];

        // 校验轮次：cancelAll 后 generation 已变，丢弃旧结果
        if (strongSelf.generation != currentGeneration) {
            [strongSelf.lock unlock];
            return;
        }

        strongSelf.loading = NO;

        // 成功时更新缓存
        if (!error && result) {
            strongSelf.cachedResult = result;
            strongSelf.cacheTime = [NSDate date];
        }

        NSArray<HYCoalescerCallback> *cbs = [strongSelf.callbacks copy];
        [strongSelf.callbacks removeAllObjects];
        [strongSelf.lock unlock];

        dispatch_async(strongSelf.callbackQueue, ^{
            for (HYCoalescerCallback cb in cbs) {
                cb(result, error);
            }
        });
    });
}

- (void)clearCache {
    [self.lock lock];
    self.cachedResult = nil;
    self.cacheTime = nil;
    [self.lock unlock];
}

- (void)cancelAll {
    [self.lock lock];
    self.generation += 1;
    [self.callbacks removeAllObjects];
    self.loading = NO;
    [self.lock unlock];
}

@end
