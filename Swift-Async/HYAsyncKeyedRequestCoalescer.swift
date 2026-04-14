/*
 *  HYAsyncKeyedRequestCoalescer.swift
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │   HYAsyncKeyedRequestCoalescer - 按 Key 去重的 async 请求合并  │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  HYKeyedRequestCoalescer 的 async/await 版本。
 *  相同 key 的并发请求只执行一次，不同 key 互不影响。
 *
 *
 *  用法示例
 *  ─────────────
 *
 *  class UserService {
 *
 *      // ── 用户信息（按 userId 去重，60秒缓存） ──
 *      private let userCoalescer = HYAsyncKeyedRequestCoalescer<String, UserInfo>(cacheTTL: 60)
 *
 *      func getUserInfo(userId: String) async throws -> UserInfo {
 *          try await userCoalescer.request(key: userId) {
 *              try await API.getUserInfo(userId: userId)
 *          }
 *      }
 *  }
 *
 *  class ImageLoader {
 *
 *      // ── 图片下载（按 URL 去重） ──
 *      private let imageCoalescer = HYAsyncKeyedRequestCoalescer<URL, Data>()
 *
 *      func loadImage(url: URL) async throws -> Data {
 *          try await imageCoalescer.request(key: url) {
 *              let (data, _) = try await URLSession.shared.data(from: url)
 *              return data
 *          }
 *      }
 *  }
 *
 *  class ListService {
 *
 *      // ── 分页数据（按页码去重） ──
 *      private let pageCoalescer = HYAsyncKeyedRequestCoalescer<Int, [Item]>()
 *
 *      func loadPage(_ page: Int) async throws -> [Item] {
 *          try await pageCoalescer.request(key: page) {
 *              try await API.getItemList(page: page)
 *          }
 *      }
 *  }
 *
 *  // ── 外部调用 ──
 *  let user  = try await UserService.shared.getUserInfo(userId: "123")
 *  let data  = try await ImageLoader.shared.loadImage(url: imageURL)
 *  let items = try await ListService.shared.loadPage(2)
 *
 *
 *  与 callback 版本的选择
 *  ─────────────────────
 *  项目已采用 async/await → HYAsyncKeyedRequestCoalescer
 *  项目仍以 callback 为主 → HYKeyedRequestCoalescer
 */

import Foundation

actor HYAsyncKeyedRequestCoalescer<Key: Hashable & Sendable, T: Sendable> {

    // MARK: - Properties

    /// 缓存有效期（秒），每个 key 独立计时。nil 表示不缓存。
    let cacheTTL: TimeInterval?

    // MARK: - Private

    private var tasks: [Key: Task<T, Error>] = [:]
    private var cache: [Key: (result: T, time: Date)] = [:]

    // MARK: - Init

    /// - Parameter cacheTTL: 缓存有效期（秒），每个 key 独立计时。nil 表示不缓存。
    init(cacheTTL: TimeInterval? = nil) {
        self.cacheTTL = cacheTTL
    }

    // MARK: - Public Methods

    /// 按 key 发起请求（相同 key 自动去重 + 可选缓存）
    ///
    /// - Parameters:
    ///   - key: 请求的唯一标识。相同 key 的并发请求会被合并，不同 key 互不影响。
    ///   - execute: 真正执行异步操作的闭包。仅在该 key 没有进行中的请求时才会被调用。
    /// - Returns: 请求结果
    func request(key: Key, execute: @Sendable @escaping () async throws -> T) async throws -> T {

        // 1. 检查缓存
        if let ttl = cacheTTL,
           let cached = cache[key],
           Date().timeIntervalSince(cached.time) < ttl {
            return cached.result
        }

        // 2. 有请求在飞 → 共享结果
        if let task = tasks[key] {
            return try await task.value
        }

        // 3. 发起新请求
        let task = Task { try await execute() }
        tasks[key] = task

        do {
            let result = try await task.value
            if cacheTTL != nil {
                cache[key] = (result, Date())
            }
            tasks.removeValue(forKey: key)
            return result
        } catch {
            tasks.removeValue(forKey: key)
            throw error
        }
    }

    /// 查询指定 key 是否有请求正在进行
    func isLoading(for key: Key) -> Bool {
        tasks[key] != nil
    }

    /// 清除指定 key 的缓存
    func clearCache(for key: Key) {
        cache.removeValue(forKey: key)
    }

    /// 清除所有 key 的缓存
    func clearAllCaches() {
        cache.removeAll()
    }

    /// 取消指定 key 的请求（等待者会收到 CancellationError）
    func cancel(for key: Key) {
        tasks[key]?.cancel()
        tasks.removeValue(forKey: key)
    }

    /// 取消所有 key 的请求
    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
