// Tweak.x — 淘宝直播间「答题抢红包」自动作答插件（TrollStore / TrollFools 注入版）
//
// 功能：
//   1. 悬浮球手动开关（默认关，点一下切换 开/关）——由你控制时机
//   2. 区域化识别：先找「提交/我知道了/确定」确认按钮定位答题弹窗，
//      只在弹窗区域内找题干和选项（避免误点直播间其他按钮/商品卡/评论）
//   3. 题干不要求带问号（"…分为几段" 这类没有问号的题也能识别）
//   4. 选择优先级：
//      ① 选项含「以上都是/以上都对」家族 → 必选
//      ② 题干含「数字+个/种/项」→ 多选：4全选 / 3随机选3 / 2随机选2
//      ③ 选项是纯数字且题干含数字（含中文数字 三→3、两→2）→ 选对应数字
//      ④ 单选 → 选文字最长项（排除肯定句陷阱）
//   5. 选项点完自动点确认按钮；若提示「火爆/繁忙/失败」循环重提直至成功
//   6. 全程随机延迟模拟真人，降低风控特征
//
// 注入：Theos + ellekit 编译 dylib → TrollFools 注入淘宝 → TrollStore 安装

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>

#pragma clang diagnostic ignored "-Wundeclared-selector"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------- 配置：模拟手速（防风控） ----------------
static const double kReadingMin   = 0.10; // 看题最短（秒）——抢红包要快
static const double kReadingMax   = 0.20; // 看题最长
static const double kOptionGapMin = 0.20; // 多选两次点击最小间隔
static const double kOptionGapMax = 0.30;
static const double kConfirmMin   = 0.20; // 选完到点确认按钮
static const double kConfirmMax   = 0.30;

// 「以上都是 / 以上都对 / 以上都选 / 以上全选」家族——选项里出现则默认必选
static NSArray<NSString *> *allAboveMarkers(void) {
    static NSArray *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @[@"以上都是", @"以上都对", @"以上都选", @"以上全选"];
    });
    return m;
}

// ---------------- 状态 ----------------
static NSArray *gBank = nil;
static BOOL gEnabled = NO;            // 悬浮球手动开关，默认关
static BOOL gWorking = NO;            // 一道题处理中
static NSMutableSet *gDoneQ = nil;    // 已处理过的题（按题干去重，防重复提交）
static NSString *gLastKey = nil;      // 当前题标识
static UIWindow *gOverlay = nil;
static UIButton *gToggleBtn = nil;

// 可编辑题库（运行时热更新，无需重装 dylib；现在仅作备份，启发式优先）
static NSString *gExternalPath = nil;   // app 沙盒 Documents/AutoAnswer_questions.json
static NSString *gBundledPath = nil;    // 内置 questions.json（随 dylib 编译进 App）
static NSDate   *gExternalMtime = nil;  // 外部题库最后加载时间

static double rnd(double a, double b) {
    return a + ((double)arc4random_uniform(10000) / 10000.0) * (b - a);
}

// ---------------- 文件日志（方便用 Filza 查看，无需 Mac/syslog） ----------------
static NSString *aaLogPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"AutoAnswer_log.txt"];
}
static void aaLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AutoAnswer] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *p = aaLogPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else    { [line writeToFile:p atomically:YES]; }
}

static void updateToggleUI(void);

// ---------------- 悬浮开关按钮 ----------------
@interface AutoAnswerBundle : NSObject @end
@implementation AutoAnswerBundle
+ (void)toggleTapped {
    gEnabled = !gEnabled;
    updateToggleUI();
    aaLog(@"手动开关 → %@", gEnabled ? @"开" : @"关");
}
@end

static void updateToggleUI(void) {
    if (!gToggleBtn) return;
    [gToggleBtn setTitle:(gEnabled ? @"答题\n开" : @"答题\n关") forState:UIControlStateNormal];
    [gToggleBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    gToggleBtn.titleLabel.numberOfLines = 2;
    gToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    gToggleBtn.backgroundColor = gEnabled
        ? [UIColor colorWithRed:0.15 green:0.65 blue:0.30 alpha:0.88]
        : [UIColor colorWithRed:0.45 green:0.12 blue:0.12 alpha:0.88];
}

static void createOverlay(UIWindowScene *scene) {
    if (gOverlay || !scene) return;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = CGRectMake(15, 200, 62, 62);
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];
    w.hidden = NO;
    w.userInteractionEnabled = YES;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = w.bounds;
    b.layer.cornerRadius = 31;
    b.layer.masksToBounds = YES;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = [UIColor whiteColor].CGColor;
    [b addTarget:[AutoAnswerBundle class]
          action:@selector(toggleTapped)
forControlEvents:UIControlEventTouchUpInside];
    [w addSubview:b];

    gOverlay = w;
    gToggleBtn = b;
    updateToggleUI();
}

// ---------------- 题库加载 ----------------
@interface AutoAnswerRes : NSObject @end
@implementation AutoAnswerRes @end

static NSArray *loadBankFromPath(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([obj isKindOfClass:[NSArray class]]) return obj;
    return nil;
}

static void loadBank(void) {
    NSBundle *b = [NSBundle bundleForClass:[AutoAnswerRes class]];
    NSString *path = [b pathForResource:@"questions" ofType:@"json"];
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"questions" ofType:@"json"];
    gBundledPath = path;
    if (path) {
        NSArray *arr = loadBankFromPath(path);
        if (arr) gBank = arr;
    }
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject;
    gExternalPath = [dir stringByAppendingPathComponent:@"AutoAnswer_questions.json"];
}

// 把一条题规范化成可比对的签名（用于去重，避免内置/外部重复）
static NSString *entrySignature(id entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return [entry description];
    NSDictionary *e = (NSDictionary *)entry;
    id a = e[@"a"] ?: @"";
    NSString *aStr = [a isKindOfClass:[NSArray class]]
        ? [[(NSArray *)a sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]
        : [a description];
    id kw = e[@"kw"] ?: @[];
    NSString *kwStr = [kw isKindOfClass:[NSArray class]]
        ? [[(NSArray *)kw sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]
        : [kw description];
    return [NSString stringWithFormat:@"%@|%@|%@", e[@"q"] ?: @"", aStr, kwStr];
}

// 【自动导入】把内置 questions.json 的新题自动合并进外部可编辑文件
static void mergeBundledIntoExternal(void) {
    if (!gBundledPath || !gExternalPath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *bundled = loadBankFromPath(gBundledPath);
    if (!bundled) return;
    NSArray *ext = loadBankFromPath(gExternalPath) ?: @[];
    NSMutableSet *have = [NSMutableSet set];
    for (id e in ext) [have addObject:entrySignature(e)];
    NSMutableArray *merged = [NSMutableArray arrayWithArray:ext];
    for (id e in bundled) {
        NSString *s = entrySignature(e);
        if (![have containsObject:s]) { [merged addObject:e]; [have addObject:s]; }
    }
    if (merged.count > ext.count) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:merged
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:nil];
        if (d && [d writeToFile:gExternalPath atomically:YES]) {
            gExternalMtime = [fm attributesOfItemAtPath:gExternalPath error:nil][NSFileModificationDate];
            aaLog(@"已自动导入内置新题，现共 %lu 条（外部原有 %lu 条保留）",
                  (unsigned long)merged.count, (unsigned long)ext.count);
        }
    }
}

// 题库热更新：外部文件优先于内置；改了文件下一次轮询（0.2s）自动生效
static void reloadBankIfNeeded(void) {
    if (!gExternalPath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:gExternalPath];
    if (!exists) {
        NSArray *base = gBank ?: @[];
        NSData *d = [NSJSONSerialization dataWithJSONObject:base
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:nil];
        if (d && [d writeToFile:gExternalPath atomically:YES]) {
            NSDictionary *attr = [fm attributesOfItemAtPath:gExternalPath error:nil];
            gExternalMtime = attr[NSFileModificationDate];
            aaLog(@"已生成可编辑题库：%@", gExternalPath);
        }
        return;
    }
    mergeBundledIntoExternal();
    NSDictionary *attr = [fm attributesOfItemAtPath:gExternalPath error:nil];
    NSDate *mtime = attr[NSFileModificationDate];
    if (!gExternalMtime || [mtime compare:gExternalMtime] == NSOrderedDescending) {
        NSArray *ext = loadBankFromPath(gExternalPath);
        if (ext) {
            gBank = ext;
            gExternalMtime = mtime;
            aaLog(@"题库热更新生效：%lu 条", (unsigned long)gBank.count);
        }
    }
}

// ---------------- 找可点击目标（选项/按钮） ----------------
// 只把「真正可点」的视图当作点击目标（UIControl 或带点按手势），
// 题干 Label 不可点，天然不会被误当成选项点下去。
static UIView *findTapTarget(UIView *view) {
    UIView *v = view;
    int depth = 0;
    while (v && depth < 6) {
        if ([v isKindOfClass:[UIControl class]]) return v;
        for (UIGestureRecognizer *g in v.gestureRecognizers)
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) return v;
        v = v.superview;
        depth++;
    }
    return nil;
}

// ---------------- 收集：全部文字（带窗口坐标）+ 可点目标 ----------------
// tappables  元素：@[文字, 可点视图, 目标在窗口坐标的frame]
// textFrames 元素：@[文字, 文字在窗口坐标的frame, 所在window（可能为 NSNull）]
static void collectViews(UIView *view, NSMutableString *allTexts,
                         NSMutableArray *tappables, NSMutableArray *textFrames) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    NSString *t = nil;
    if ([view isKindOfClass:[UILabel class]])         t = [(UILabel *)view text];
    else if ([view isKindOfClass:[UITextView class]]) t = [(UITextView *)view text];
    else if ([view respondsToSelector:@selector(text)]) {
        id x = [view performSelector:@selector(text)];
        if ([x isKindOfClass:[NSString class]]) t = x;
    }
    if (t.length) {
        [allTexts appendFormat:@"%@\n", t];
        if (textFrames) {
            CGRect wf = [view convertRect:view.bounds toView:nil];
            id wnd = view.window ?: (id)[NSNull null];
            [textFrames addObject:@[t, [NSValue valueWithCGRect:wf], wnd]];
        }
        UIView *target = findTapTarget(view);
        if (target) {
            CGRect tf = [target convertRect:target.bounds toView:nil];
            [tappables addObject:@[t, target, [NSValue valueWithCGRect:tf]]];
        }
    }
    for (UIView *c in view.subviews) collectViews(c, allTexts, tappables, textFrames);
}

// ---------------- 网页视图检测（诊断用） ----------------
static NSInteger gWebViewCount = 0;
static void scanWebViews(UIView *v) {
    if (!v) return;
    Class wk  = NSClassFromString(@"WKWebView");
    Class uiw = NSClassFromString(@"UIWebView");
    if ((wk  && [v isKindOfClass:wk])  || (uiw && [v isKindOfClass:uiw])) gWebViewCount++;
    for (UIView *c in v.subviews) scanWebViews(c);
}
// 注意：早期版本曾在此对屏上每个 WKWebView 自动跑 evaluateJavaScript 读 DOM，
// 会在淘宝主页大量 WebView 未就绪时导致 App 闪退，已移除。

// ---------------- 找确认按钮（提交/确认/我知道了/确定…） ----------------
// 确认按钮是定位答题弹窗的锚点：选项都在它上方、同一窗口内。
static UIView *findConfirmBtn(NSArray *tappables, CGRect *outFrame) {
    static NSArray *markers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[@"提交", @"确认", @"我知道了", @"知道了", @"确定", @"交卷"];
    });
    for (NSArray *p in tappables) {
        if (p.count < 3) continue;
        NSString *t = p[0];
        if (t.length == 0 || t.length > 10) continue;
        for (NSString *m in markers) {
            if ([t containsString:m]) {
                if (outFrame) *outFrame = [(NSValue *)p[2] CGRectValue];
                return p[1];
            }
        }
    }
    return nil;
}

// ---------------- 题干里的数字（阿拉伯/中文都认） ----------------
// "圣歌兰臻研三段分域面颈膜，分为几段" → 三 → 3 → 匹配纯数字选项 "3"
static NSInteger firstNumeralIn(NSString *s) {
    if (s.length == 0) return 0;
    NSDictionary *cn = @{@"一":@1, @"二":@2, @"两":@2, @"三":@3, @"四":@4,
                         @"五":@5, @"六":@6, @"七":@7, @"八":@8, @"九":@9, @"十":@10};
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if (ch >= '1' && ch <= '9') return ch - '0';
        NSString *c = [s substringWithRange:NSMakeRange(i, 1)];
        NSNumber *v = cn[c];
        if (v) return v.intValue;
    }
    return 0;
}

// ---------------- 肯定句判定（单选题里这类多为陷阱，不选） ----------------
static BOOL isAffirmativeSentence(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || t.length == 0) return NO;
    NSArray *markers = @[@"确实",@"当然",@"肯定",@"毫无疑问",@"没错",@"是的",
                         @"对，",@"就是这样",@"一定",@"绝对"];
    for (NSString *m in markers)
        if ([t containsString:m] && (t.length > 8 || [t containsString:@"。"])) return YES;
    return NO;
}

// ---------------- 点击（已加固：绝不因点击崩溃） ----------------
static void tapView(UIView *view) {
    if (!view) return;
    @try {
        // 1) 本身是 UIControl（按钮等）→ 直接触发，最安全
        if ([view isKindOfClass:[UIControl class]]) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
        // 2) 中心命中测试找子 UIControl（很多选项是按钮包在容器里）
        CGRect r = view.bounds;
        if (r.size.width > 0 && r.size.height > 0) {
            UIView *hit = [view hitTest:CGPointMake(r.size.width/2, r.size.height/2) withEvent:nil];
            if (hit && hit != view && [hit isKindOfClass:[UIControl class]]) {
                [(UIControl *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
        }
        // 3) 兜底：手势 target/action（最不安全，做足防护再调用）
        for (UIGestureRecognizer *g in view.gestureRecognizers) {
            if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
            id target = nil;
            @try { target = [g valueForKey:@"_target"]; } @catch (id) { target = nil; }
            SEL action = NULL;
            Ivar aIvar = class_getInstanceVariable(object_getClass(g), "_action");
            if (aIvar) {
                action = (SEL)(__bridge void *)object_getIvar(g, aIvar);
            }
            if (target && action && [target respondsToSelector:action]) {
                ((void(*)(id,SEL,id))objc_msgSend)(target, action, g);
                return;
            }
        }
    } @catch (NSException *e) {
        aaLog(@"[异常] tapView 跳过：%@", e);
    }
}

// ---------------- 提交后循环重提（遇「火爆/繁忙」） ----------------
static void retrySubmitIfBusy(UIView *confirm, NSInteger left) {
    @try {
        NSMutableString *all2 = [NSMutableString string];
        NSMutableArray *tap2 = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ((UIWindowScene *)s).windows)
                        if (!w.isHidden && w.alpha > 0.01) collectViews(w, all2, tap2, nil);
                }
            }
        }
        BOOL busy = NO;
        for (NSString *k in @[@"火爆",@"繁忙",@"失败",@"稍后",@"重试",@"超时",@"抢不到",@"人太多",@"网络"]) {
            if ([all2 containsString:k]) { busy = YES; break; }
        }
        UIView *confirm2 = findConfirmBtn(tap2, NULL);
        if (busy && confirm2 && left > 0) {
            aaLog(@"检测到提交繁忙，重提（剩 %ld 次）", (long)left);
            tapView(confirm2);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rnd(0.4, 0.7) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ retrySubmitIfBusy(confirm2, left - 1); });
        } else {
            aaLog(@"提交流程结束（busy=%d, left=%ld）", busy, (long)left);
            gWorking = NO;
        }
    } @catch (NSException *e) {
        aaLog(@"[异常] 重提流程：%@", e);
        gWorking = NO;
    }
}

// ---------------- 主循环 ----------------
static void tick(void) {
    // 悬浮球懒创建：必须放在所有提前 return 之前（无条件创建）
    if (!gOverlay) {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
        createOverlay(sc);
    }

    if (!gEnabled || gWorking) return;
    @try {

    reloadBankIfNeeded();

    // 收集前台场景里【所有 window】的文字（带坐标）与可点目标
    NSMutableString *all = [NSMutableString string];
    NSMutableArray *tappables = [NSMutableArray array];
    NSMutableArray *textFrames = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)s).windows)
                    if (!w.isHidden && w.alpha > 0.01) collectViews(w, all, tappables, textFrames);
            }
        }
    } else {
        collectViews(UIApplication.sharedApplication.keyWindow, all, tappables, textFrames);
    }

    // 统计屏上网页视图数量（诊断用）
    gWebViewCount = 0;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)s).windows)
                    if (!w.isHidden && w.alpha > 0.01) scanWebViews(w);
            }
        }
    } else {
        scanWebViews(UIApplication.sharedApplication.keyWindow);
    }

    // ===== 定位答题弹窗：以确认按钮（提交/我知道了/确定）为锚点 =====
    static NSArray *nonOptionWords = nil;
    static dispatch_once_t onceNon;
    dispatch_once(&onceNon, ^{
        nonOptionWords = @[@"返回",@"关闭",@"首页",@"我的",@"购物车",@"分享",@"举报",@"客服",
                           @"下一题",@"上一题",@"跳过",@"换一换",@"更多",@"取消"];
    });

    CGRect confirmFrame = CGRectZero;
    UIView *confirm = findConfirmBtn(tappables, &confirmFrame);
    NSString *confirmText = @"";
    if (confirm) {
        for (NSArray *p in tappables)
            if (p.count >= 3 && p[1] == confirm) { confirmText = p[0]; break; }
    }

    // 选项候选：确认按钮上方 520pt 内、与确认按钮同窗口、文字 <= 40 字
    NSMutableArray *options = [NSMutableArray array];
    if (confirm) {
        UIWindow *cw = confirm.window;
        for (NSArray *p in tappables) {
            if (p.count < 3) continue;
            UIView *v = p[1];
            if (v == confirm) continue;
            if (gToggleBtn && v == gToggleBtn) continue;
            if (cw && v.window != cw) continue;                 // 必须与确认按钮同窗口
            CGRect f = [(NSValue *)p[2] CGRectValue];
            if (f.maxY > confirmFrame.minY + 4) continue;       // 必须在确认按钮上方
            if (f.minY < confirmFrame.minY - 520) continue;     // 必须在弹窗区域内
            NSString *t = p[0];
            if (t.length == 0 || t.length > 40) continue;       // 排除商品卡等超长文本
            BOOL skip = NO;
            for (NSString *w in nonOptionWords) if ([t containsString:w]) { skip = YES; break; }
            if (skip) continue;
            [options addObject:p];
        }
    }

    // 题干：所有选项上方 260pt 内、同窗口的最长文字（不要求带问号）
    NSString *qText = @"";
    if (options.count >= 2) {
        CGFloat optionsMinY = CGFLOAT_MAX;
        for (NSArray *p in options) {
            CGRect f = [(NSValue *)p[2] CGRectValue];
            if (f.minY < optionsMinY) optionsMinY = f.minY;
        }
        UIWindow *cw = confirm.window;
        for (NSArray *p in textFrames) {
            if (p.count < 3) continue;
            id wnd = p[2];
            if (![wnd isKindOfClass:[UIView class]]) continue;
            if (cw && wnd != cw) continue;
            NSString *t = p[0];
            if (t.length < 2) continue;
            if ([t containsString:@"答题抢红包"] || [t containsString:@"已结束"] ||
                [t containsString:@"超时"]   || [t containsString:@"红包"]) continue;
            CGRect f = [(NSValue *)p[1] CGRectValue];
            if (f.maxY > optionsMinY + 4) continue;             // 必须在所有选项上方
            if (f.maxY < optionsMinY - 260) continue;           // 且不能太远（排除屏顶横幅）
            if (t.length > qText.length) qText = t;
        }
    }

    // 诊断日志（每 2 秒）：把识别结果也打出来，便于远程调试
    {
        static NSDate *gLastDiag2 = nil;
        NSDate *now = [NSDate date];
        if (!gLastDiag2 || [now timeIntervalSinceDate:gLastDiag2] > 2.0) {
            gLastDiag2 = now;
            aaLog(@"[诊断] 文字%lu 可点%lu 网页%ld | 确认=%@ 选项%lu 题干=%@",
                  (unsigned long)all.length, (unsigned long)tappables.count, (long)gWebViewCount,
                  confirmText.length ? confirmText : (confirm ? @"有" : @"无"),
                  (unsigned long)options.count, qText.length ? qText : @"-");
            if (all.length < 2) {
                if (gWebViewCount > 0) {
                    aaLog(@"[诊断] 原生读不到文字但屏上有 %ld 个网页视图 → 可能答题界面是网页(WebView)渲染",
                          (long)gWebViewCount);
                } else {
                    aaLog(@"[诊断] 原生读不到文字且无网页视图 → 可能：不是淘宝主App / dylib 未注入 / 开关没开");
                }
            }
        }
    }

    if (!confirm || options.count < 2) return;   // 屏上没有答题弹窗
    if (all.length < 2) return;

    NSString *qkey = qText.length ? qText : @"选项串";
    if (qText.length == 0) {
        NSMutableArray *ts = [NSMutableArray array];
        for (NSArray *p in options) [ts addObject:p[0]];
        qkey = [ts componentsJoinedByString:@"|"];
    }
    if (![qkey isEqualToString:gLastKey]) {  // 换题了，重置已点记录
        gLastKey = qkey;
        [gDoneQ removeAllObjects];
    }
    if ([gDoneQ containsObject:qkey]) return; // 这道题已经处理过（防重复提交）

    // ===== 启发式自动作答 =====
    NSMutableArray *optViews = [NSMutableArray array];
    NSMutableArray *optTexts = [NSMutableArray array];

    // ① 「以上都是」家族必选
    NSMutableArray *allAbove = [NSMutableArray array];
    for (NSArray *p in options) {
        for (NSString *m in allAboveMarkers())
            if ([p[0] containsString:m]) { [allAbove addObject:p]; break; }
    }

    if (allAbove.count > 0) {
        for (NSArray *p in allAbove)
            if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
        aaLog(@"命中「以上都是」必选，共 %lu 项", (unsigned long)optViews.count);
    } else {
        // ② 多选：题干含「数字+个/种/项」→ 4全选 / 3随机3 / 2随机2
        BOOL isMulti = NO; NSInteger needN = 0;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d)\\s*[个种项]"
                                                                              options:0 error:nil];
        NSArray *ms = [re matchesInString:qText options:0 range:NSMakeRange(0, qText.length)];
        NSInteger best = 0;
        for (NSTextCheckingResult *m in ms) {
            NSInteger d = [[qText substringWithRange:[m rangeAtIndex:1]] integerValue];
            if (d == 4) { best = 4; break; }
            if (d == 3 && best < 3) best = 3;
            if (d == 2 && best < 2) best = 2;
        }
        if (best > 0) { isMulti = YES; needN = best; }

        if (isMulti) {
            NSMutableArray *pool = [NSMutableArray arrayWithArray:options];
            if (needN >= (NSInteger)pool.count) {
                for (NSArray *p in pool)
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
                aaLog(@"多选：全选 %lu 项（needN=%ld）", (unsigned long)optViews.count, (long)needN);
            } else {
                while (optViews.count < needN && pool.count) {
                    NSUInteger idx = arc4random_uniform((uint32_t)pool.count);
                    NSArray *p = pool[idx];
                    [pool removeObjectAtIndex:idx];
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
                }
                aaLog(@"多选：随机选 %lu 项（needN=%ld）", (unsigned long)optViews.count, (long)needN);
            }
        } else {
            // ③ 纯数字选项 + 题干数字匹配（含中文数字：三→3）
            NSInteger n = firstNumeralIn(qText);
            if (n > 0) {
                for (NSArray *p in options) {
                    NSString *t = p[0];
                    BOOL pureNum = (t.length >= 1 && t.length <= 3);
                    for (NSUInteger i = 0; pureNum && i < t.length; i++) {
                        unichar ch = [t characterAtIndex:i];
                        if (ch < '0' || ch > '9') pureNum = NO;
                    }
                    if (pureNum && t.intValue == n) {
                        [optViews addObject:p[1]]; [optTexts addObject:t];
                        aaLog(@"数字匹配：题干含数字 %ld → 选「%@」", (long)n, t);
                        break;
                    }
                }
            }
            // ④ 单选最长（排除肯定句；全被排除则退化选最长）
            if (!optViews.count) {
                NSString *bestText = nil; UIView *bestView = nil; NSUInteger bestLen = 0;
                for (NSArray *p in options) {
                    NSString *t = p[0];
                    if (isAffirmativeSentence(t)) continue;
                    if (t.length > bestLen) { bestLen = t.length; bestText = t; bestView = p[1]; }
                }
                if (!bestView) {
                    for (NSArray *p in options) {
                        NSString *t = p[0];
                        if (t.length > bestLen) { bestLen = t.length; bestText = t; bestView = p[1]; }
                    }
                }
                if (bestView) { [optViews addObject:bestView]; [optTexts addObject:bestText]; }
                aaLog(@"单选：选最长项（%lu 字符）%@", (unsigned long)bestLen, bestText ?: @"");
            }
        }
    }

    if (!optViews.count) return;

    // ===== 模拟手速：看题 → 逐个点选项（随机间隔）→ 点确认 → 火爆则循环重提 =====
    gWorking = YES;
    [gDoneQ addObject:qkey];
    double reading = rnd(kReadingMin, kReadingMax);
    aaLog(@"作答 %@，看题 %.1fs", optTexts, reading);

    void (^doSubmit)(void) = ^{
        if (confirm) { tapView(confirm); aaLog(@"已点「%@」", confirmText); }
        else         { aaLog(@"未找到确认按钮，跳过提交"); }
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(reading * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        double offset = 0;
        for (NSUInteger i = 0; i < optViews.count; i++) {
            if (i > 0) offset += rnd(kOptionGapMin, kOptionGapMax);
            UIView *v = optViews[i];
            NSString *txt = optTexts[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(offset * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { tapView(v); aaLog(@"已选：%@", txt); }
                @catch (NSException *e) { aaLog(@"[异常] 选项点击：%@", e); }
            });
        }
        double confirmAt = offset + rnd(kConfirmMin, kConfirmMax);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(confirmAt * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            doSubmit();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { retrySubmitIfBusy(confirm, 8); }
                @catch (NSException *e) { aaLog(@"[异常] 重提：%@", e); gWorking = NO; }
            });
        });
    });
    } @catch (NSException *e) {
        aaLog(@"[异常] tick 抛出异常：%@", e);
    }
}

%ctor {
    @try { [[NSFileManager defaultManager] removeItemAtPath:aaLogPath() error:nil]; } @catch (...) {}
    loadBank();
    reloadBankIfNeeded();   // 首次启动把内置题库复制成可编辑文件
    gDoneQ = [NSMutableSet set];
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                    repeats:YES
                                      block:^(NSTimer *t){ tick(); }];
    aaLog(@"插件已加载（区域化识别版），内置题库 %lu 条\n默认关闭（点悬浮球开启）",
          (unsigned long)(gBank ? gBank.count : 0));
}
