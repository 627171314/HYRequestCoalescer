/*
 *  HYAsyncRequestCoalescer.swift
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │        HYAsyncRequestCoalescer - async/await 请求合并工具     │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  HYRequestCoalescer 的 async/await 版本。
 *  用 actor 替代 NSLock，用 Task.value 替代回调数组，功能等价，写法更简洁。
 *
 *  对照关系
 *  ─────────────
 *  ┌───────────────────────────┬──────────────────────────────────┐
 *  │ callback 版本              │ async/await 版本                  │
 *  ├───────────────────────────┼──────────────────────────────────┤
 *  │ HYRequestCoalescer        │ HYAsyncRequestCoalescer（本文件）  │
 *  │ NSLock                    │ actor 隔离                       │
 *  │ callbacks 数组             │ Task.value 多次 await             │
 *  │ generation 计数器          │ Task.cancel()                    │
 *  │ completion 闭包            │ 直接 return / throw               │
 *  │ callbackQueue 配置         │ 不需要（由调用方决定线程）          │
 *  └───────────────────────────┴──────────────────────────────────┘
 *
 *
 *  用法示例
 *  ─────────────
 *
 *  class DeviceManager {
 *
 *      // ── BLE 设备文件列表 ──
 *      private let fileListCoalescer = HYAsyncRequestCoalescer<[DeviceFile]>()
 *
 *      func getFileList() async throws -> [DeviceFile] {
 *          try await fileListCoalescer.request {
 *              try await device.getFileList()
 *          }
 *      }
 *
 *      // ── BLE 设备存储信息 ──
 *      private let storageCoalescer = HYAsyncRequestCoalescer<DeviceStorageInfo>()
 *
 *      func getStorageInfo() async throws -> DeviceStorageInfo {
 *          try await storageCoalescer.request {
 *              let info = try await device.getStorageInfo()
 *              self.storageInfo = info
 *              return info
 *          }
 *      }
 *  }
 *
 *  class UserService {
 *
 *      // ── 用户信息（60秒缓存） ──
 *      private let userInfoCoalescer = HYAsyncRequestCoalescer<UserInfo>(cacheTTL: 60)
 *
 *      func getUserInfo() async throws -> UserInfo {
 *          try await userInfoCoalescer.request {
 *              try await API.getUserInfo()
 *          }
 *      }
 *
 *      // ── Token 刷新 ──
 *      private let tokenCoalescer = HYAsyncRequestCoalescer<String>()
 *
 *      func refreshToken() async throws -> String {
 *          try await tokenCoalescer.request {
 *              try await AuthService.refreshToken()
 *          }
 *      }
 *  }
 *
 *  // ── 外部调用 ──
 *  let files = try await DeviceManager.shared.getFileList()
 *  let user  = try await UserService.shared.getUserInfo()
 *  let token = try await UserService.shared.refreshToken()
 *
 *
 *  与 callback 版本的选择
 *  ─────────────────────
 *  项目已采用 async/await → HYAsyncRequestCoalescer
 *  项目仍以 callback 为主 → HYRequestCoalescer
 */

import Foundation

actor HYAsyncRequestCoalescer<T: Sendable> {

    // MARK: - Properties

    /// 缓存有效期（秒）。nil 表示不缓存。
    let cacheTTL: TimeInterval?

    /// 是否有请求正在进行中
    var isLoading: Bool { task != nil }

    // MARK: - Private

    private var task: Task<T, Error>?
    private var cachedResult: T?
    private var cacheTime: Date?

    // MARK: - Init

    /// - Parameter cacheTTL: 缓存有效期（秒）。nil 表示不缓存，每次都执行真实请求。
    init(cacheTTL: TimeInterval? = nil) {
        self.cacheTTL = cacheTTL
    }

    // MARK: - Public Methods

    /// 发起请求（自动去重 + 可选缓存）
    ///
    /// 多个调用者同时 await 时，只执行一次 execute，所有调用者共享同一份结果。
    ///
    /// - Parameter execute: 真正执行异步操作的闭包。仅在没有进行中的请求时才会被调用。
    /// - Returns: 请求结果（可能来自缓存、进行中的请求、或新请求）
    func request(execute: @Sendable @escaping () async throws -> T) async throws -> T {

        // 1. 检查缓存
        if let ttl = cacheTTL,
           let cached = cachedResult,
           let time = cacheTime,
           Date().timeIntervalSince(time) < ttl {
            return cached
        }

        // 2. 有请求在飞 → 共享结果
        if let task = task {
            return try await task.value
        }

        // 3. 发起新请求
        let task = Task { try await execute() }
        self.task = task

        do {
            let result = try await task.value
            self.cachedResult = result
            self.cacheTime = Date()
            self.task = nil
            return result
        } catch {
            self.task = nil
            throw error
        }
    }

    /// 清除缓存
    func clearCache() {
        cachedResult = nil
        cacheTime = nil
    }

    /// 取消进行中的请求
    /// 所有正在 await 的调用者会收到 CancellationError
    func cancelAll() {
        task?.cancel()
        task = nil
    }
}
