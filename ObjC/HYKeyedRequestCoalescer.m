#import "HYKeyedRequestCoalescer.h"

@interface HYKeyedRequestCoalescer ()

@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableDictionary<id<NSCopying>, HYRequestCoalescer *> *coalescers;

@end

@implementation HYKeyedRequestCoalescer

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
        _coalescers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Public

- (void)requestWithKey:(id<NSCopying>)key
               execute:(void (^)(HYCoalescerCallback))execute
            completion:(HYCoalescerCallback)completion {
    HYRequestCoalescer *coalescer = [self coalescerForKey:key];

    __weak typeof(self) weakSelf = self;
    [coalescer requestWithExecute:execute completion:^(id _Nullable result, NSError * _Nullable error) {
        completion(result, error);

        // 无缓存模式下，请求完成后自动释放闲置的 key 实例
        if (weakSelf.cacheTTL <= 0) {
            [weakSelf removeIfIdleForKey:key];
        }
    }];
}

- (BOOL)isLoadingForKey:(id<NSCopying>)key {
    [self.lock lock];
    HYRequestCoalescer *coalescer = self.coalescers[key];
    [self.lock unlock];
    return coalescer ? coalescer.isLoading : NO;
}

- (void)clearCacheForKey:(id<NSCopying>)key {
    [self.lock lock];
    HYRequestCoalescer *coalescer = self.coalescers[key];
    [self.lock unlock];
    [coalescer clearCache];
}

- (void)clearAllCaches {
    [self.lock lock];
    NSArray *all = self.coalescers.allValues;
    [self.coalescers removeAllObjects];
    [self.lock unlock];
    for (HYRequestCoalescer *c in all) {
        [c clearCache];
    }
}

- (void)cancelForKey:(id<NSCopying>)key {
    [self.lock lock];
    HYRequestCoalescer *coalescer = self.coalescers[key];
    [self.coalescers removeObjectForKey:key];
    [self.lock unlock];
    [coalescer cancelAll];
}

- (void)cancelAll {
    [self.lock lock];
    NSArray *all = self.coalescers.allValues;
    [self.coalescers removeAllObjects];
    [self.lock unlock];
    for (HYRequestCoalescer *c in all) {
        [c cancelAll];
    }
}

#pragma mark - Private

- (HYRequestCoalescer *)coalescerForKey:(id<NSCopying>)key {
    [self.lock lock];
    HYRequestCoalescer *coalescer = self.coalescers[key];
    if (!coalescer) {
        coalescer = [[HYRequestCoalescer alloc] initWithCacheTTL:self.cacheTTL
                                                   callbackQueue:self.callbackQueue];
        self.coalescers[key] = coalescer;
    }
    [self.lock unlock];
    return coalescer;
}

- (void)removeIfIdleForKey:(id<NSCopying>)key {
    [self.lock lock];
    HYRequestCoalescer *coalescer = self.coalescers[key];
    if (coalescer && !coalescer.isLoading) {
        [self.coalescers removeObjectForKey:key];
    }
    [self.lock unlock];
}

@end
