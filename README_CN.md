[English](README.md) | [中文](README_CN.md)

# HYRequestCoalescer

**异步请求合并工具** — 多个调用者同时发起相同的异步请求时，只执行一次，所有调用者共享同一份结果。

零依赖，直接拖源文件到项目里用。

## 解决什么问题

多个调用者同时发起**相同的异步请求**时，只执行一次，所有调用者共享同一份结果。
避免重复请求带来的资源浪费、数据冲突或状态紊乱。

```
页面A ──→ getFileList() ──┐
                          ├──→ 只执行一次 ──→ 结果同时返回给 A、B、C
页面B ──→ getFileList() ──┤
                          │
页面C ──→ getFileList() ──┘
```

常见场景：
- 多个页面同时需要同一份数据（用户信息、配置、设备文件列表）
- 多个网络请求同时 401，只需触发一次 Token 刷新
- 同一张图片被多个 cell 请求，只需下载一次
- BLE 设备指令串行执行，多处并发调用需要排队共享

## 三套实现

按项目技术栈选择，功能完全等价：

| 实现 | 适用项目 | 文件 |
|------|---------|------|
| **Swift (Callback)** | Swift 项目，callback 风格 | `HYRequestCoalescer.swift` + `HYKeyedRequestCoalescer.swift` |
| **Swift (async/await)** | Swift 项目，已采用 async/await | `HYAsyncRequestCoalescer.swift` + `HYAsyncKeyedRequestCoalescer.swift` |
| **Objective-C** | 纯 OC 或混编项目 | `HYRequestCoalescer.h/.m` + `HYKeyedRequestCoalescer.h/.m` |

每套都包含两个类：

| 类 | 用途 |
|----|------|
| `HYRequestCoalescer` | 所有调用者要同一份数据（无参数区分） |
| `HYKeyedRequestCoalescer` | 按参数（key）区分，相同 key 共享，不同 key 独立 |

## 安装

直接拖对应的源文件到项目中，不需要 CocoaPods / SPM / Carthage。

**Swift Callback** → 拖入 `HYRequestCoalescer.swift` + `HYKeyedRequestCoalescer.swift`

**Swift async/await** → 拖入 `HYAsyncRequestCoalescer.swift` + `HYAsyncKeyedRequestCoalescer.swift`

**Objective-C** → 拖入 `HYRequestCoalescer.h/.m` + `HYKeyedRequestCoalescer.h/.m`

> 类前缀为 `HY`，如需改为你自己的前缀，全局替换 `HY` 即可。

## 能力一览

| 能力 | 说明 |
|------|------|
| 请求去重 | 同一时刻多次调用，只执行一次，结果共享给所有等待者 |
| 线程安全 | NSLock / actor 保护内部状态，支持多线程并发调用 |
| isLoading | 外部可查询是否有请求正在进行 |
| TTL 缓存 | 可选启用，如 `init(cacheTTL: 60)` 表示 60 秒内直接返回缓存 |
| 清除缓存 | `clearCache()`，退出登录 / 解绑设备时调用 |
| 取消回调 | `cancelAll()`，页面销毁 / 连接断开时丢弃等待中的回调 |
| 回调线程 | 默认主线程，可配置（async/await 版本由调用方决定） |

## 用法

### 核心思路

在 Manager / Service 内部持有 coalescer 实例，对外只暴露简洁的异步方法。  
调用方完全不感知 coalescer 的存在。

---

### Swift (Callback)

```swift
class DeviceManager {

    private let fileListCoalescer = HYRequestCoalescer<[DeviceFile]>()

    func getFileList(completion: @escaping ([DeviceFile]?, Error?) -> Void) {
        fileListCoalescer.request(execute: { [weak self] callback in
            self?.device.getFileList { files, error in
                callback(files, error)
            }
        }, completion: completion)
    }
}

// 外部调用
DeviceManager.shared.getFileList { files, error in
    // 无论多少处同时调用，只会发一次真实请求
}
```

按 key 去重：

```swift
class UserService {

    private let userCoalescer = HYKeyedRequestCoalescer<String, UserInfo>(cacheTTL: 60)

    func getUserInfo(userId: String, completion: @escaping (UserInfo?, Error?) -> Void) {
        userCoalescer.request(key: userId, execute: { callback in
            API.getUserInfo(userId: userId) { user, error in
                callback(user, error)
            }
        }, completion: completion)
    }
}
```

---

### Swift (async/await)

```swift
class DeviceManager {

    private let fileListCoalescer = HYAsyncRequestCoalescer<[DeviceFile]>()

    func getFileList() async throws -> [DeviceFile] {
        try await fileListCoalescer.request {
            try await device.getFileList()
        }
    }
}

// 外部调用
let files = try await DeviceManager.shared.getFileList()
```

按 key 去重：

```swift
class UserService {

    private let userCoalescer = HYAsyncKeyedRequestCoalescer<String, UserInfo>(cacheTTL: 60)

    func getUserInfo(userId: String) async throws -> UserInfo {
        try await userCoalescer.request(key: userId) {
            try await API.getUserInfo(userId: userId)
        }
    }
}
```

---

### Objective-C

```objc
@interface DeviceManager ()
@property (nonatomic, strong) HYRequestCoalescer *fileListCoalescer;
@end

@implementation DeviceManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileListCoalescer = [[HYRequestCoalescer alloc] init];
    }
    return self;
}

- (void)getFileList:(void (^)(NSArray *files, NSError *error))completion {
    [self.fileListCoalescer requestWithExecute:^(HYCoalescerCallback callback) {
        [self.device getFileList:^(NSArray *files, NSError *error) {
            callback(files, error);
        }];
    } completion:^(id result, NSError *error) {
        completion((NSArray *)result, error);
    }];
}

@end

// 外部调用
[[DeviceManager shared] getFileList:^(NSArray *files, NSError *error) {
    // ...
}];
```

按 key 去重：

```objc
@interface UserService ()
@property (nonatomic, strong) HYKeyedRequestCoalescer *userCoalescer;
@end

@implementation UserService

- (instancetype)init {
    self = [super init];
    if (self) {
        _userCoalescer = [[HYKeyedRequestCoalescer alloc] initWithCacheTTL:60
                                                             callbackQueue:dispatch_get_main_queue()];
    }
    return self;
}

- (void)getUserInfo:(NSString *)userId completion:(void (^)(UserInfo *, NSError *))completion {
    [self.userCoalescer requestWithKey:userId execute:^(HYCoalescerCallback callback) {
        [API getUserInfo:userId completion:^(UserInfo *user, NSError *error) {
            callback(user, error);
        }];
    } completion:^(id result, NSError *error) {
        completion((UserInfo *)result, error);
    }];
}

@end
```

## 适用条件

满足以下三个条件即可使用：

1. **请求参数相同** — 多个调用者要的是同一份数据
2. **结果可共享** — 一份结果能满足所有等待者
3. **并发时机不确定** — 无法预知谁先调、谁后调

如果请求参数不同（如查不同用户），使用 `HYKeyedRequestCoalescer`，按参数做 key 区分。

## 三套实现的选择

```
项目是 OC？
  └─ 是 → ObjC 版本
  └─ 否 → 项目用了 async/await？
              └─ 是 → Swift async/await 版本
              └─ 否 → Swift callback 版本
```

## License

MIT
