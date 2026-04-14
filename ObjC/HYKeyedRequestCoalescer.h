/*
 *  HYKeyedRequestCoalescer.h
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │      HYKeyedRequestCoalescer - OC 版按 Key 去重的请求合并工具   │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  HYRequestCoalescer 的 keyed 版本。
 *  相同 key 的并发请求只执行一次，不同 key 互不影响。
 *  内部为每个 key 创建独立的 HYRequestCoalescer 实例。
 *
 *
 *  用法示例
 *  ─────────────
 *
 *  @interface UserService ()
 *  @property (nonatomic, strong) HYKeyedRequestCoalescer *userCoalescer;
 *  @end
 *
 *  @implementation UserService
 *
 *  - (instancetype)init {
 *      self = [super init];
 *      if (self) {
 *          // 60秒缓存
 *          _userCoalescer = [[HYKeyedRequestCoalescer alloc] initWithCacheTTL:60
 *                                                              callbackQueue:dispatch_get_main_queue()];
 *      }
 *      return self;
 *  }
 *
 *  // ── 用户信息（按 userId 去重） ──
 *  - (void)getUserInfo:(NSString *)userId completion:(void (^)(UserInfo *, NSError *))completion {
 *      [self.userCoalescer requestWithKey:userId execute:^(HYCoalescerCallback callback) {
 *          [API getUserInfo:userId completion:^(UserInfo *user, NSError *error) {
 *              callback(user, error);
 *          }];
 *      } completion:^(id result, NSError *error) {
 *          completion((UserInfo *)result, error);
 *      }];
 *  }
 *
 *  @end
 *
 *  // ── 外部调用 ──
 *  [[UserService shared] getUserInfo:@"123" completion:^(UserInfo *user, NSError *error) { ... }];
 */

#import <Foundation/Foundation.h>
#import "HYRequestCoalescer.h"

NS_ASSUME_NONNULL_BEGIN

@interface HYKeyedRequestCoalescer : NSObject

/// 缓存有效期（秒），应用于每个 key。<= 0 表示不缓存。
@property (nonatomic, readonly) NSTimeInterval cacheTTL;

/// 回调分发线程。默认主线程。
@property (nonatomic, strong, readonly) dispatch_queue_t callbackQueue;

/// 不缓存，主线程回调
- (instancetype)init;

/// @param cacheTTL 缓存有效期（秒），每个 key 独立计时。<= 0 表示不缓存。
/// @param callbackQueue 回调分发线程。
- (instancetype)initWithCacheTTL:(NSTimeInterval)cacheTTL
                   callbackQueue:(dispatch_queue_t)callbackQueue NS_DESIGNATED_INITIALIZER;

/// 按 key 发起请求（相同 key 自动去重 + 可选缓存）
///
/// @param key 请求的唯一标识（需实现 NSCopying）。相同 key 的并发请求会被合并。
/// @param execute 真正执行异步操作的 block。仅在该 key 没有进行中的请求时才会被调用。
/// @param completion 调用方的回调。
- (void)requestWithKey:(id<NSCopying>)key
               execute:(void (^)(HYCoalescerCallback callback))execute
            completion:(HYCoalescerCallback)completion;

/// 查询指定 key 是否有请求正在进行
- (BOOL)isLoadingForKey:(id<NSCopying>)key;

/// 清除指定 key 的缓存
- (void)clearCacheForKey:(id<NSCopying>)key;

/// 清除所有 key 的缓存并释放内部实例
- (void)clearAllCaches;

/// 取消指定 key 的所有等待中回调
- (void)cancelForKey:(id<NSCopying>)key;

/// 取消所有 key 的等待中回调并释放内部实例
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
