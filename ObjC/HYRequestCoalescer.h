/*
 *  HYRequestCoalescer.h
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │          HYRequestCoalescer - OC 版异步请求合并工具             │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  RequestCoalescer 的 Objective-C 版本。
 *  功能等价于 Swift callback 版本，适用于纯 OC 或混编项目。
 *
 *  与 Swift 版本的区别
 *  ─────────────────
 *  - 无泛型，结果类型为 id，调用方需自行强转
 *  - cacheTTL <= 0 表示不缓存（Swift 用 nil）
 *
 *
 *  用法示例
 *  ─────────────
 *
 *  @interface DeviceManager ()
 *  @property (nonatomic, strong) HYRequestCoalescer *fileListCoalescer;
 *  @property (nonatomic, strong) HYRequestCoalescer *storageCoalescer;
 *  @end
 *
 *  @implementation DeviceManager
 *
 *  - (instancetype)init {
 *      self = [super init];
 *      if (self) {
 *          _fileListCoalescer = [[HYRequestCoalescer alloc] init];
 *          _storageCoalescer  = [[HYRequestCoalescer alloc] init];
 *      }
 *      return self;
 *  }
 *
 *  // ── BLE 设备文件列表 ──
 *  - (void)getFileList:(void (^)(NSArray *files, NSError *error))completion {
 *      [self.fileListCoalescer requestWithExecute:^(HYCoalescerCallback callback) {
 *          [self.device getFileList:^(NSArray *files, NSError *error) {
 *              callback(files, error);
 *          }];
 *      } completion:^(id result, NSError *error) {
 *          completion((NSArray *)result, error);  // 强转
 *      }];
 *  }
 *
 *  // ── BLE 设备存储信息 ──
 *  - (void)getStorageInfo:(void (^)(DeviceStorageInfo *info, NSError *error))completion {
 *      [self.storageCoalescer requestWithExecute:^(HYCoalescerCallback callback) {
 *          [self.device getStorageInfo:^(DeviceStorageInfo *info, NSError *error) {
 *              if (info) self.storageInfo = info;
 *              callback(info, error);
 *          }];
 *      } completion:^(id result, NSError *error) {
 *          completion((DeviceStorageInfo *)result, error);
 *      }];
 *  }
 *
 *  @end
 *
 *  // ── 外部调用（无需关心内部 coalescer） ──
 *  [[DeviceManager shared] getFileList:^(NSArray *files, NSError *error) { ... }];
 *  [[DeviceManager shared] getStorageInfo:^(DeviceStorageInfo *info, NSError *error) { ... }];
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 通用回调类型：(result, error)
typedef void (^HYCoalescerCallback)(id _Nullable result, NSError * _Nullable error);

@interface HYRequestCoalescer : NSObject

/// 缓存有效期（秒）。<= 0 表示不缓存。
@property (nonatomic, readonly) NSTimeInterval cacheTTL;

/// 回调分发线程。默认主线程。
@property (nonatomic, strong, readonly) dispatch_queue_t callbackQueue;

/// 是否有请求正在进行中
@property (nonatomic, readonly) BOOL isLoading;

/// 不缓存，主线程回调
- (instancetype)init;

/// @param cacheTTL 缓存有效期（秒）。<= 0 表示不缓存。
/// @param callbackQueue 回调分发线程。
- (instancetype)initWithCacheTTL:(NSTimeInterval)cacheTTL
                   callbackQueue:(dispatch_queue_t)callbackQueue NS_DESIGNATED_INITIALIZER;

/// 发起请求（自动去重 + 可选缓存）
///
/// @param execute 真正执行异步操作的 block。接收一个 callback，操作完成后调用 callback 传回结果。
///                仅在没有进行中的请求时才会被调用。
/// @param completion 调用方的回调。结果可能来自缓存、进行中的请求、或新请求。
- (void)requestWithExecute:(void (^)(HYCoalescerCallback callback))execute
                completion:(HYCoalescerCallback)completion;

/// 清除缓存
- (void)clearCache;

/// 取消所有等待中的回调并重置状态。
/// 飞行中的请求结果返回后会被自动丢弃（通过 generation 校验）。
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
