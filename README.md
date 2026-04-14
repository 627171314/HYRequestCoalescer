[English](README.md) | [中文](README_CN.md)

# HYRequestCoalescer

**Async Request Coalescing Utility** — When multiple callers fire the same async request simultaneously, only one execution happens and the result is shared with all callers.

Zero dependencies. Just drag the source files into your project.

## What Problem Does It Solve

When multiple callers fire the **same async request** simultaneously, only one execution happens and the result is shared with all callers.
Eliminates redundant requests that cause wasted resources, data conflicts, or inconsistent state.

```
Screen A ──→ getFileList() ──┐
                             ├──→ executes once ──→ result delivered to A, B, C
Screen B ──→ getFileList() ──┤
                             │
Screen C ──→ getFileList() ──┘
```

Common scenarios:
- Multiple screens need the same data at once (user info, config, device file list)
- Multiple network requests get 401 — only one token refresh is needed
- Same image requested by multiple cells — only one download
- BLE device commands are serial — concurrent callers need to queue and share

## Three Implementations

Pick the one that matches your tech stack. All are functionally equivalent:

| Implementation | Target Project | Files |
|----------------|---------------|-------|
| **Swift (Callback)** | Swift projects, callback style | `HYRequestCoalescer.swift` + `HYKeyedRequestCoalescer.swift` |
| **Swift (async/await)** | Swift projects using async/await | `HYAsyncRequestCoalescer.swift` + `HYAsyncKeyedRequestCoalescer.swift` |
| **Objective-C** | Pure OC or mixed projects | `HYRequestCoalescer.h/.m` + `HYKeyedRequestCoalescer.h/.m` |

Each implementation includes two classes:

| Class | Purpose |
|-------|---------|
| `HYRequestCoalescer` | All callers want the same data (no parameter differentiation) |
| `HYKeyedRequestCoalescer` | Callers differentiated by key — same key shares, different keys are independent |

## Installation

Drag the source files directly into your project. No CocoaPods / SPM / Carthage needed.

**Swift Callback** → Drag in `HYRequestCoalescer.swift` + `HYKeyedRequestCoalescer.swift`

**Swift async/await** → Drag in `HYAsyncRequestCoalescer.swift` + `HYAsyncKeyedRequestCoalescer.swift`

**Objective-C** → Drag in `HYRequestCoalescer.h/.m` + `HYKeyedRequestCoalescer.h/.m`

> The class prefix is `HY`. To use your own prefix, just find-and-replace `HY` globally.

## Features

| Feature | Description |
|---------|-------------|
| Request Dedup | Multiple concurrent calls → only one execution, result shared with all waiters |
| Thread Safety | NSLock / actor protects internal state, safe for multi-threaded access |
| isLoading | Query whether a request is currently in-flight |
| TTL Cache | Optional — `init(cacheTTL: 60)` enables 60-second result caching |
| Clear Cache | `clearCache()` — call on logout / device unbind |
| Cancel | `cancelAll()` — discard pending callbacks on page dismiss / disconnect |
| Callback Queue | Defaults to main queue, configurable (async/await version is caller-decided) |

## Usage

### Core Pattern

Hold a coalescer instance as a private property inside your Manager / Service.  
Expose only clean async methods to the outside. Callers never see the coalescer.

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

// External call
DeviceManager.shared.getFileList { files, error in
    // No matter how many places call this simultaneously, only one real request fires
}
```

Keyed dedup:

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

// External call
let files = try await DeviceManager.shared.getFileList()
```

Keyed dedup:

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

// External call
[[DeviceManager shared] getFileList:^(NSArray *files, NSError *error) {
    // ...
}];
```

Keyed dedup:

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

## When to Use

Use it when all three conditions are met:

1. **Same parameters** — multiple callers want the same data
2. **Shareable result** — one result satisfies all waiters
3. **Unpredictable concurrency** — you can't predict who calls first

If parameters differ (e.g. different user IDs), use `HYKeyedRequestCoalescer` to differentiate by key.

## Choosing an Implementation

```
Is your project OC?
  └─ Yes → Objective-C version
  └─ No  → Using async/await?
               └─ Yes → Swift async/await version
               └─ No  → Swift callback version
```

## License

MIT
