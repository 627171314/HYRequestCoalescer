/*
 *  HYKeyedRequestCoalescer.swift
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │       HYKeyedRequestCoalescer - 按 Key 去重的异步请求合并工具   │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  与 HYRequestCoalescer 的区别
 *  ─────────────────────────
 *  HYRequestCoalescer       → 所有调用者要的是同一份数据，共享一个请求
 *  HYKeyedRequestCoalescer  → 调用者按 key 分组，相同 key 共享，不同 key 独立
 *
 *  内部实现：每个 key 自动创建一个 HYRequestCoalescer 实例，复用其全部能力
 *  （请求去重、线程安全、TTL 缓存、回调线程配置）
 *
 *
 *  能力一览
 *  ─────────────
 *  ┌────────────────┬──────────────────────────────────────────────┐
 *  │ 按 key 去重     │ 相同 key 的并发请求只执行一次，不同 key 互不影响  │
 *  │ 线程安全        │ 字典访问加锁，每个 key 的状态独立加锁            │
 *  │ isLoading(for:) │ 查询指定 key 是否有请求正在进行                │
 *  │ TTL 缓存        │ 每个 key 独立缓存，可选启用                    │
 *  │ 清除缓存        │ clearCache(for:) 按 key 清除 / clearAll() 全清 │
 *  │ 取消回调        │ cancel(for:) 按 key 取消 / cancelAll() 全取消  │
 *  │ 回调线程        │ 默认主线程，可配置                             │
 *  │ 自动释放        │ 无缓存模式下，请求完成后自动移除闲置的 key 实例    │
 *  └────────────────┴──────────────────────────────────────────────┘
 *
 *
 *  用法示例
 *  ─────────────
 *  在 Manager / Service 内部持有 coalescer，对外只暴露简洁的异步方法。
 *  外部调用者无需知道 coalescer 的存在。
 *
 *  class UserService {
 *
 *      // ── 用户信息 ──
 *      // 不同用户 ID 独立去重，60秒缓存
 *      private let userCoalescer = HYKeyedRequestCoalescer<String, UserInfo>(cacheTTL: 60)
 *
 *      func getUserInfo(userId: String, completion: @escaping (UserInfo?, Error?) -> Void) {
 *          userCoalescer.request(key: userId, execute: { callback in
 *              API.getUserInfo(userId: userId) { user, error in
 *                  callback(user, error)
 *              }
 *          }, completion: completion)
 *      }
 *  }
 *
 *  class ImageLoader {
 *
 *      // ── 图片下载 ──
 *      // 按 URL 去重，同一张图被多个 cell 请求时只下载一次
 *      private let imageCoalescer = HYKeyedRequestCoalescer<URL, Data>()
 *
 *      func loadImage(url: URL, completion: @escaping (Data?, Error?) -> Void) {
 *          imageCoalescer.request(key: url, execute: { callback in
 *              URLSession.shared.dataTask(with: url) { data, _, error in
 *                  callback(data, error)
 *              }.resume()
 *          }, completion: completion)
 *      }
 *  }
 *
 *  class ListService {
 *
 *      // ── 分页数据 ──
 *      // 按页码去重，防止快速滚动时同一页被重复加载
 *      private let pageCoalescer = HYKeyedRequestCoalescer<Int, [Item]>()
 *
 *      func loadPage(_ page: Int, completion: @escaping ([Item]?, Error?) -> Void) {
 *          pageCoalescer.request(key: page, execute: { callback in
 *              API.getItemList(page: page) { items, error in
 *                  callback(items, error)
 *              }
 *          }, completion: completion)
 *      }
 *  }
 *
 *  // ── 外部调用（无需关心内部 coalescer） ──
 *  UserService.shared.getUserInfo(userId: "123") { user, error in ... }
 *  ImageLoader.shared.loadImage(url: imageURL) { data, error in ... }
 *  ListService.shared.loadPage(2) { items, error in ... }
 *
 *
 *  与 HYRequestCoalescer 的选择
 *  ─────────────────────────
 *  所有请求要同一份数据（如设备文件列表、全局配置）→ HYRequestCoalescer
 *  请求按参数区分（如不同用户、不同URL、不同页码）→ HYKeyedRequestCoalescer
 */

import Foundation

class HYKeyedRequestCoalescer<Key: Hashable, T> {

    // MARK: - Properties

    /// 缓存有效期（秒），应用于每个 key。nil 表示不缓存。
    let cacheTTL: TimeInterval?

    /// 回调分发线程，应用于每个 key。默认主线程。
    let callbackQueue: DispatchQueue

    // MARK: - Private

    private let lock = NSLock()
    private var coalescers: [Key: HYRequestCoalescer<T>] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - cacheTTL: 缓存有效期（秒），每个 key 独立计时。nil 表示不缓存。
    ///   - callbackQueue: 回调分发线程。默认 .main。
    init(cacheTTL: TimeInterval? = nil, callbackQueue: DispatchQueue = .main) {
        self.cacheTTL = cacheTTL
        self.callbackQueue = callbackQueue
    }

    // MARK: - Public Methods

    /// 按 key 发起请求（相同 key 自动去重 + 可选缓存）
    ///
    /// - Parameters:
    ///   - key: 请求的唯一标识。相同 key 的并发请求会被合并，不同 key 互不影响。
    ///   - execute: 真正执行异步操作的闭包。仅在该 key 没有进行中的请求时才会被调用。
    ///   - completion: 调用者的回调。
    func request(
        key: Key,
        execute: @escaping (@escaping (T?, Error?) -> Void) -> Void,
        completion: @escaping (T?, Error?) -> Void
    ) {
        let coalescer = getOrCreateCoalescer(for: key)
        coalescer.request(execute: execute) { [weak self] result, error in
            completion(result, error)

            // 无缓存模式下，请求完成且无后续等待者时，自动释放该 key 的实例，防止字典无限增长
            if self?.cacheTTL == nil {
                self?.removeIfIdle(key: key)
            }
        }
    }

    /// 查询指定 key 是否有请求正在进行
    func isLoading(for key: Key) -> Bool {
        lock.lock()
        let coalescer = coalescers[key]
        lock.unlock()
        return coalescer?.isLoading ?? false
    }

    /// 清除指定 key 的缓存
    func clearCache(for key: Key) {
        lock.lock()
        let coalescer = coalescers[key]
        lock.unlock()
        coalescer?.clearCache()
    }

    /// 清除所有 key 的缓存并释放内部实例
    func clearAllCaches() {
        lock.lock()
        let all = coalescers.values
        coalescers.removeAll()
        lock.unlock()
        all.forEach { $0.clearCache() }
    }

    /// 取消指定 key 的所有等待中回调
    func cancel(for key: Key) {
        lock.lock()
        let coalescer = coalescers.removeValue(forKey: key)
        lock.unlock()
        coalescer?.cancelAll()
    }

    /// 取消所有 key 的等待中回调并释放内部实例
    func cancelAll() {
        lock.lock()
        let all = coalescers.values
        coalescers.removeAll()
        lock.unlock()
        all.forEach { $0.cancelAll() }
    }

    // MARK: - Private

    private func getOrCreateCoalescer(for key: Key) -> HYRequestCoalescer<T> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = coalescers[key] {
            return existing
        }

        let coalescer = HYRequestCoalescer<T>(cacheTTL: cacheTTL, callbackQueue: callbackQueue)
        coalescers[key] = coalescer
        return coalescer
    }

    /// 请求完成后，如果该 key 的 coalescer 已空闲（不在加载），从字典中移除以释放内存
    private func removeIfIdle(key: Key) {
        lock.lock()
        if let coalescer = coalescers[key], !coalescer.isLoading {
            coalescers.removeValue(forKey: key)
        }
        lock.unlock()
    }
}
