#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ========== Bundle ID 伪装 ==========
// 当应用被重签名/侧载后，Bundle ID 会改变，导致服务器拒绝登录
// 这里全方位伪装 Bundle ID，覆盖系统 API 和所有 HTTP 请求头

static NSString *const kOriginalBundleID = @"com.ss.iphone.ugc.Aweme";

// 所有可能出现在 HTTP 请求头中的 Bundle ID 字段名
static NSArray *gBundleIDHeaderKeys = nil;

static void initHeaderKeys() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gBundleIDHeaderKeys = @[
            @"X-App-Bundle-ID",   @"x-app-bundle-id",
            @"X-Bundle-ID",       @"x-bundle-id",
            @"App-Bundle-ID",     @"app-bundle-id",
            @"Bundle-Identifier", @"bundle-identifier",
            @"CFBundleIdentifier",
            @"bundleId",          @"bundle_id",
            @"bundle_identifier",
        ];
    });
}

// 判断一个 header key 是否是 Bundle ID 相关字段
static BOOL isBundleIDHeader(NSString *key) {
    if (!key) return NO;
    NSString *lower = [key lowercaseString];
    for (NSString *k in gBundleIDHeaderKeys) {
        if ([lower isEqualToString:[k lowercaseString]]) {
            return YES;
        }
    }
    return NO;
}

// 替换字典中所有 Bundle ID 值
static NSDictionary *fixHeaderDict(NSDictionary *headers) {
    if (!headers || ![headers isKindOfClass:[NSDictionary class]]) return headers;
    NSMutableDictionary *fixed = [headers mutableCopy];
    BOOL changed = NO;
    for (NSString *key in headers) {
        if (isBundleIDHeader(key)) {
            fixed[key] = kOriginalBundleID;
            changed = YES;
        }
    }
    return changed ? [fixed copy] : headers;
}

// ========== Hook NSBundle ==========

%hook NSBundle

- (NSString *)bundleIdentifier {
    NSString *orig = %orig;
    if (!orig) return orig;
    // 只替换抖音相关的 Bundle ID
    if ([orig containsString:@"Aweme"] || [orig containsString:@"aweme"]) {
        return kOriginalBundleID;
    }
    return orig;
}

// 同时 hook infoDictionary，确保 CFBundleIdentifier 一致
- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (!orig) return orig;
    NSString *bid = orig[@"CFBundleIdentifier"];
    if (bid && ([bid containsString:@"Aweme"] || [bid containsString:@"aweme"])) {
        NSMutableDictionary *fixed = [orig mutableCopy];
        fixed[@"CFBundleIdentifier"] = kOriginalBundleID;
        return [fixed copy];
    }
    return orig;
}

%end

// ========== Hook NSURLRequest ==========

%hook NSURLRequest

- (NSDictionary *)allHTTPHeaderFields {
    return fixHeaderDict(%orig);
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field {
    NSString *val = %orig;
    if (val && isBundleIDHeader(field)) {
        return kOriginalBundleID;
    }
    return val;
}

%end

// ========== Hook NSMutableURLRequest ==========

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (value && isBundleIDHeader(field)) {
        %orig(kOriginalBundleID, field);
    } else {
        %orig;
    }
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (value && isBundleIDHeader(field)) {
        %orig(kOriginalBundleID, field);
    } else {
        %orig;
    }
}

%end

// ========== Hook NSURLSessionConfiguration ==========

%hook NSURLSessionConfiguration

- (NSDictionary *)HTTPAdditionalHeaders {
    return fixHeaderDict(%orig);
}

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    %orig(fixHeaderDict(headers));
}

%end

// ========== 屏蔽"应用版本过低"强制升级弹窗 ==========

%hook AWEAccountForceUpgradeManager

+ (BOOL)shouldShowUpgradeAPPPanel {
    return NO;
}

- (void)showUpgradeAPPPanelWithMessage:(id)message {
    NSLog(@"[DYComment] Blocked force upgrade panel");
}

- (void)showUpgradeAPPPanelWithMessage:(id)message completion:(id)completion {
    NSLog(@"[DYComment] Blocked force upgrade panel (with completion)");
}

%end

// ========== 屏蔽登录窗口内的"版本过低"弹窗 ==========

%hook AWELoginAlertView

+ (void)showAlertWithTitle:(id)title description:(id)desc imageName:(id)img leftButtonTitle:(id)left rightButtonTitle:(id)right leftActionBlock:(id)leftBlock rightActionBlock:(id)rightBlock {
    NSString *descStr = nil;
    if ([desc isKindOfClass:[NSString class]]) {
        descStr = desc;
    }
    // 拦截包含"版本过低"的弹窗
    if (descStr && [descStr containsString:@"版本过低"]) {
        NSLog(@"[DYComment] Blocked AWELoginAlertView: %@", descStr);
        return;
    }
    %orig;
}

%end

// ========== 初始化 ==========

%ctor {
    initHeaderKeys();
    NSLog(@"[DYComment] BundleIDSpoof loaded, target: %@", kOriginalBundleID);
}
