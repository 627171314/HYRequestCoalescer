/*
 *  HYRequestCoalescer.swift
 *
 *  ┌─────────────────────────────────────────────────────────────┐
 *  │             HYRequestCoalescer - 异步请求合并工具类             │
 *  └─────────────────────────────────────────────────────────────┘
 *
 *  解决什么问题？
 *  ─────────────
 *  多个调用者同时发起 **相同的异步请求** 时，只执行一次，所有调用者共享同一份结果。
 *  避免重复请求带来的资源浪费、数据冲突或状态紊乱。
 *
 *
 *  能力一览
 *  ─────────────
 *  ┌──────────┬──────────────────────────────────────────────────┐
 *  │ 请求去重  │ 同一时刻多次调用，只执行一次，结果共享给所有等待者       │
 *  │ 线程安全  │ NSLock 保护内部状态，支持多线程并发调用               │
 *  │ isLoading │ 只读属性，外部可判断是否有请求正在进行                │
 *  │ TTL 缓存  │ 可选，init(cacheTTL: 60) 即启用60秒缓存            │
 *  │ 清除缓存  │ clearCache()，解绑设备/退出登录时调用               │
 *  │ 取消回调  │ cancelAll()，页面销毁/设备断连时丢弃所有等待中的回调   │
 *  │ 回调线程  │ 默认主线程，可通过 init(callbackQueue:) 配置         │
 *  └──────────┴──────────────────────────────────────────────────┘
 *
 *
 *  用法示例
 *  ─────────────
 *  在 Manager / Service 内部持有 coalescer，对外只暴露简洁的异步方法。
 *  外部调用者无需知道 coalescer 的存在，像调普通异步方法一样使用。
 *
 *  class DeviceManager {
 *
 *      // ── BLE 设备指令 ──
 *      // 多个页面同时需要设备文件列表，只发一次 BLE 命令
 *      private let fileListCoalescer = HYRequestCoalescer<[DeviceFile]>()
 *
 *      func getFileList(completion: @escaping ([DeviceFile]?, Error?) -> Void) {
 *          fileListCoalescer.request(execute: { [weak self] callback in
 *              self?.device.getFileList { files, error in
 *                  callback(files, error)
 *              }
 *          }, completion: completion)
 *      }
 *
 *      // ── BLE 设备存储信息 ──
 *      private let storageCoalescer = HYRequestCoalescer<DeviceStorageInfo>()
 *
 *      func getStorageInfo(completion: @escaping (DeviceStorageInfo?, Error?) -> Void) {
 *          storageCoalescer.request(execute: { [weak self] callback in
 *              self?.device.getStorageInfo { info, error in
 *                  if let info = info { self?.storageInfo = info }
 *                  callback(info, error)
 *              }
 *          }, completion: completion)
 *      }
 *  }
 *
 *  class UserService {
 *
 *      // ── 网络请求 ──
 *      // 多个模块同时需要用户信息，只发一次 HTTP 请求，60秒内走缓存
 *      private let userInfoCoalescer = HYRequestCoalescer<UserInfo>(cacheTTL: 60)
 *
 *      func getUserInfo(completion: @escaping (UserInfo?, Error?) -> Void) {
 *          userInfoCoalescer.request(execute: { callback in
 *              API.getUserInfo { user, error in
 *                  callback(user, error)
 *              }
 *          }, completion: completion)
 *      }
 *
 *      // ── Token 刷新 ──
 *      // 多个请求同时 401，只触发一次 refreshToken
 *      private let tokenCoalescer = HYRequestCoalescer<String>()
 *
 *      func refreshToken(completion: @escaping (String?, Error?) -> Void) {
 *          tokenCoalescer.request(execute: { callback in
 *              AuthService.refreshToken { newToken, error in
 *                  callback(newToken, error)
 *              }
 *          }, completion: completion)
 *      }
 *  }
 *
 *  class ConfigManager {
 *
 *      // ── 远端配置 ──
 *      // App 多处依赖远端配置，启动时只拉一次，1小时缓存
 *      private let configCoalescer = HYRequestCoalescer<AppConfig>(cacheTTL: 3600)
 *
 *      func fetchConfig(completion: @escaping (AppConfig?, Error?) -> Void) {
 *          configCoalescer.request(execute: { callback in
 *              ConfigService.fetchRemoteConfig { config, error in
 *                  callback(config, error)
 *              }
 *          }, completion: completion)
 *      }
 *
 *      // ── 数据库查询 ──
 *      // 多个模块同时查同一份数据，合并成一次查询，10秒缓存
 *      private let dbCoalescer = HYRequestCoalescer<[Record]>(cacheTTL: 10)
 *
 *      func queryRecords(completion: @escaping ([Record]?, Error?) -> Void) {
 *          dbCoalescer.request(execute: { callback in
 *              DatabaseManager.query("SELECT * FROM records") { records, error in
 *                  callback(records, error)
 *              }
 *          }, completion: completion)
 *      }
 *
 *      // ── 文件 IO ──
 *      // 多处同时读取同一个配置文件，合并为一次磁盘读取
 *      private let fileCoalescer = HYRequestCoalescer<Data>()
 *
 *      func readConfigFile(at url: URL, completion: @escaping (Data?, Error?) -> Void) {
 *          fileCoalescer.request(execute: { callback in
 *              DispatchQueue.global().async {
 *                  let data = try? Data(contentsOf: url)
 *                  callback(data, nil)
 *              }
 *          }, completion: completion)
 *      }
 *  }
 *
 *  // ── 外部调用（无需关心内部 coalescer） ──
 *  DeviceManager.shared.getFileList { files, error in ... }
 *  DeviceManager.shared.getStorageInfo { info, error in ... }
 *  UserService.shared.getUserInfo { user, error in ... }
 *  UserService.shared.refreshToken { token, error in ... }
 *  ConfigManager.shared.fetchConfig { config, error in ... }
 *
 *
 *  适用条件
 *  ─────────────
 *  满足以下三个条件即可使用：
 *  1. 请求参数相同（多个调用者要的是同一份数据）
 *  2. 结果可共享（一份结果能满足所有等待者）
 *  3. 并发时机不确定（无法预知谁先调、谁后调）
 *
 *  如果请求参数不同（如查不同用户），按参数做 key 区分 → HYKeyedRequestCoalescer
 */

import Foundation

class HYRequestCoalescer<T> {

    // MARK: - Properties

    /// 缓存有效期（秒）。nil 表示不缓存。
    let cacheTTL: TimeInterval?

    /// 回调分发线程。默认主线程，适合 UI 更新场景。
    let callbackQueue: DispatchQueue

    /// 是否有请求正在进行中（只读）
    var isLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isLoading
    }

    // MARK: - Private

    private let lock = NSLock()
    private var _isLoading = false
    private var callbacks: [(T?, Error?) -> Void] = []
    private var generation: UInt64 = 0  // 用于标记请求轮次，cancelAll 后递增，旧请求回来时校验

    // 缓存
    private var cachedResult: T?
    private var cacheTime: Date?

    // MARK: - Init

    /// - Parameters:
    ///   - cacheTTL: 缓存有效期（秒）。nil 表示不缓存，每次都执行真实请求。
    ///   - callbackQueue: 回调分发线程。默认 .main。
    init(cacheTTL: TimeInterval? = nil, callbackQueue: DispatchQueue = .main) {
        self.cacheTTL = cacheTTL
        self.callbackQueue = callbackQueue
    }

    // MARK: - Public Methods

    /// 发起请求（自动去重 + 可选缓存）
    ///
    /// - Parameters:
    ///   - execute: 真正执行异步操作的闭包。接收一个 callback，操作完成后调用 callback 传回结果。
    ///             仅在没有进行中的请求时才会被调用。
    ///   - completion: 调用者的回调。无论是从缓存、从进行中的请求、还是新请求，都会通过此回调返回结果。
    func request(
        execute: @escaping (@escaping (T?, Error?) -> Void) -> Void,
        completion: @escaping (T?, Error?) -> Void
    ) {
        lock.lock()

        // 1. 检查缓存
        if let ttl = cacheTTL,
           let cached = cachedResult,
           let time = cacheTime,
           Date().timeIntervalSince(time) < ttl {
            lock.unlock()
            callbackQueue.async { completion(cached, nil) }
            return
        }

        // 2. 加入等待队列
        callbacks.append(completion)

        // 3. 如果已有请求在飞，只排队不重复发
        if _isLoading {
            lock.unlock()
            return
        }

        // 4. 标记加载中，发起真实请求
        _isLoading = true
        let currentGeneration = generation
        lock.unlock()

        execute { [weak self] result, error in
            guard let self = self else { return }

            self.lock.lock()

            // 校验请求轮次：如果 cancelAll() 被调用过，generation 已变，丢弃旧结果
            guard self.generation == currentGeneration else {
                self.lock.unlock()
                return
            }

            self._isLoading = false

            // 成功时更新缓存
            if error == nil, let result = result {
                self.cachedResult = result
                self.cacheTime = Date()
            }

            let cbs = self.callbacks
            self.callbacks.removeAll()
            self.lock.unlock()

            // 在指定线程分发结果给所有等待者
            self.callbackQueue.async {
                cbs.forEach { $0(result, error) }
            }
        }
    }

    /// 清除缓存（解绑设备、退出登录等场景使用）
    func clearCache() {
        lock.lock()
        cachedResult = nil
        cacheTime = nil
        lock.unlock()
    }

    /// 取消所有等待中的回调并重置状态
    /// 适用于页面销毁、设备断开等需要丢弃所有回调的场景
    /// 注意：如果有请求正在飞行中，其结果返回后会被自动丢弃（通过 generation 校验）
    func cancelAll() {
        lock.lock()
        generation += 1  // 递增轮次，使飞行中的旧请求回来后自动失效
        callbacks.removeAll()
        _isLoading = false
        lock.unlock()
    }
}
