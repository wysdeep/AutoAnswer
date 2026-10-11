// Tweak.x — 淘宝直播间「答题抢红包」自动作答插件（TrollStore / TrollFools 注入版）
//
// 功能：
//   1. 悬浮球手动开关（默认关，点一下切换 开/关）——由你控制时机
//   2. 反向识别：先找出屏上所有「可点载体」（UIControl 或带点按手势的视图，不限层级深度），
//      再看每个载体框住了哪些文字 → 得到「文字+可点目标」对。
//      确认按钮（提交/确认/我知道了/确定…）为锚点定位答题弹窗，
//      只在弹窗区域内（确认按钮上方、同窗口）找题干和选项。
//   3. 题干不要求带问号（"…分为几段" 这类没有问号的题也能识别）
//   4. 选择优先级：
//      ① 选项含「以上都是/以上都对」家族 → 必选
//      ② 题干含「数字+个/种/项」→ 多选：4全选 / 3随机选3 / 2随机选2
//      ③ 选项是纯数字且题干含数字（含中文数字 三→3、两→2）→ 选对应数字
//      ④ 单选 → 选文字最长项（排除肯定句陷阱）
//   5. 选项点完自动点确认按钮；若提示「火爆/繁忙/失败」循环重提直至成功
//   6. 全程随机延迟模拟真人，降低风控特征
//   7. 诊断日志极详细：发现新题记快照；找不到选项时 dump 区域内所有可点项
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
static const double kReadingMin   = 0.10; // 看题最短（秒）
static const double kReadingMax   = 0.20;
static const double kOptionGapMin = 0.20; // 多选两次点击最小间隔
static const double kOptionGapMax = 0.30;
static const double kConfirmMin   = 0.20; // 选完到点确认按钮
static const double kConfirmMax   = 0.30;

// 「以上都是 / 以上都对 / 以上都选 / 以上全选」家族
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
static BOOL gEnabled = NO;
static BOOL gWorking = NO;
static NSMutableSet *gDoneQ = nil;
static NSString *gLastKey = nil;
static UIWindow *gOverlay = nil;
static UIButton *gToggleBtn = nil;

static NSString *gExternalPath = nil;
static NSString *gBundledPath = nil;
static NSDate   *gExternalMtime = nil;

static double rnd(double a, double b) {
    return a + ((double)arc4random_uniform(10000) / 10000.0) * (b - a);
}

// ---------------- 文件日志 ----------------
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

// ---------------- 收集①：全部文字（带窗口坐标） ----------------
// textFrames 元素：@[文字, 窗口坐标frame, 所在window（可能为 NSNull）]
static void collectViews(UIView *view, NSMutableString *allTexts, NSMutableArray *textFrames) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    NSString *t = nil;
    if ([view isKindOfClass:[UILabel class]])         t = [(UILabel *)view text];
    else if ([view isKindOfClass:[UITextView class]]) t = [(UITextView *)view text];
    else if ([view isKindOfClass:[UIButton class]])   t = [(UIButton *)view titleForState:UIControlStateNormal];
    else if ([view respondsToSelector:@selector(text)]) {
        id x = [view performSelector:@selector(text)];
        if ([x isKindOfClass:[NSString class]]) t = x;
    }
    if (t.length && textFrames) {
        [allTexts appendFormat:@"%@\n", t];
        CGRect wf = [view convertRect:view.bounds toView:nil];
        id wnd = view.window ?: (id)[NSNull null];
        [textFrames addObject:@[t, [NSValue valueWithCGRect:wf], wnd]];
    }
    for (UIView *c in view.subviews) collectViews(c, allTexts, textFrames);
}

// ---------------- 收集②：可点载体（UIControl 或带点按手势，不限深度） ----------------
// targets 元素：@[载体view, 窗口坐标frame, 所在window（可能为 NSNull）]
static void collectTapTargets(UIView *view, NSMutableArray *targets) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    BOOL isCtrl = NO;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)view;
        isCtrl = c.enabled && c.userInteractionEnabled;
    }
    BOOL hasTap = NO;
    if (!isCtrl && view.userInteractionEnabled) {
        for (UIGestureRecognizer *g in view.gestureRecognizers)
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) { hasTap = YES; break; }
    }
    if (isCtrl || hasTap) {
        CGRect f = [view convertRect:view.bounds toView:nil];
        id wnd = view.window ?: (id)[NSNull null];
        [targets addObject:@[view, [NSValue valueWithCGRect:f], wnd]];
    }
    for (UIView *c in view.subviews) collectTapTargets(c, targets);
}

// ---------------- 整屏扫描：文字归属到最小的可点载体 ----------------
// 产出 tappables 元素：@[文字, 载体view, 载体窗口坐标frame]（同名去重，保留最小=最内层真实按钮）
static void scanScreen(NSMutableString *all, NSMutableArray *tappables, NSMutableArray *textFrames) {
    NSMutableArray *targets = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w.isHidden || w.alpha < 0.01) continue;
                    collectViews(w, all, textFrames);
                    collectTapTargets(w, targets);
                }
            }
        }
    } else {
        UIWindow *kw = UIApplication.sharedApplication.keyWindow;
        collectViews(kw, all, textFrames);
        collectTapTargets(kw, targets);
    }

    NSMutableDictionary *best = [NSMutableDictionary dictionary];
    for (NSArray *tp in targets) {
        if (tp.count < 3) continue;
        id tw = tp[2];
        if (![tw isKindOfClass:[UIView class]]) continue;
        UIView *tv = tp[0];
        CGRect tf = [(NSValue *)tp[1] CGRectValue];
        NSMutableString *txt = [NSMutableString string];
        for (NSArray *p in textFrames) {
            if (p.count < 3) continue;
            if (p[2] != tw) continue;                     // 必须同窗口
            CGRect lf = [(NSValue *)p[1] CGRectValue];
            if (CGRectContainsRect(tf, lf)) {
                if (txt.length) [txt appendString:@" "];
                [txt appendString:p[0]];
            }
        }
        if (!txt.length) continue;
        NSArray *entry = @[[NSString stringWithString:txt], tv, tp[1]];
        NSArray *cur = best[txt];
        if (!cur) { best[txt] = entry; continue; }
        CGRect cf = [(NSValue *)cur[2] CGRectValue];
        if (tf.size.width * tf.size.height < cf.size.width * cf.size.height) best[txt] = entry;
    }
    [tappables addObjectsFromArray:best.allValues];
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

// ---------------- 找确认按钮（提交/确认/我知道了/确定…） ----------------
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

// ---------------- 肯定句判定 ----------------
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
        if ([view isKindOfClass:[UIControl class]]) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
        CGRect r = view.bounds;
        if (r.size.width > 0 && r.size.height > 0) {
            UIView *hit = [view hitTest:CGPointMake(r.size.width/2, r.size.height/2) withEvent:nil];
            if (hit && hit != view && [hit isKindOfClass:[UIControl class]]) {
                [(UIControl *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
        }
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
        NSMutableArray *tf2 = [NSMutableArray array];
        scanScreen(all2, tap2, tf2);
        BOOL busy = NO;
        for (NSString *k in @[@"火爆",@"繁忙",@"失败",@"稍后",@"重试",@"超时",@"抢不到",@"人太多"]) {
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
    if (!gOverlay) {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
        createOverlay(sc);
    }

    if (!gEnabled || gWorking) return;
    @try {

    reloadBankIfNeeded();

    NSMutableString *all = [NSMutableString string];
    NSMutableArray *tappables = [NSMutableArray array];
    NSMutableArray *textFrames = [NSMutableArray array];
    scanScreen(all, tappables, textFrames);

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

    // ===== 定位答题弹窗：以确认按钮为锚点 =====
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

    // ===== 答题语境判定：必须出现「答题/红包/剩余/抢答」等字样，才认为在答题弹窗 =====
    // 否则屏上大量直播间弹幕/聊天会被误当选项（日志已证实旧版因此乱答聊天）
    BOOL hasQuiz = NO;
    for (NSArray *p in textFrames) {
        if (p.count < 3) continue;
        NSString *tt = p[0];
        if ([tt containsString:@"答题"] || [tt containsString:@"红包"] ||
            [tt containsString:@"剩余"] || [tt containsString:@"抢答"] ||
            [tt containsString:@"答题时间"] || [tt containsString:@"倒计时"]) { hasQuiz = YES; break; }
    }

    // 选项候选：确认按钮上方 520pt 内、同窗口、文字 ≤ 40 字
    NSMutableArray *options = [NSMutableArray array];
    if (confirm) {
        UIWindow *cw = confirm.window;
        for (NSArray *p in tappables) {
            if (p.count < 3) continue;
            UIView *v = p[1];
            if (v == confirm) continue;
            if (gToggleBtn && v == gToggleBtn) continue;
            if (cw && v.window != cw) continue;
            CGRect f = [(NSValue *)p[2] CGRectValue];
            if (CGRectGetMaxY(f) > CGRectGetMinY(confirmFrame) + 4) continue;
            if (CGRectGetMinY(f) < CGRectGetMinY(confirmFrame) - 520) continue;
            NSString *t = p[0];
            if (t.length == 0 || t.length > 40) continue;
            // 排除直播间弹幕/聊天（形如「话***: 佳琦…」带冒号或 *** 昵称）
            if ([t containsString:@":"] || [t containsString:@"***"]) continue;
            BOOL skip = NO;
            for (NSString *w in nonOptionWords) if ([t containsString:w]) { skip = YES; break; }
            if (skip) continue;
            [options addObject:p];
        }
    }

    // 题干：所有选项上方 260pt 内、同窗口的最长文字（不要求问号）
    NSString *qText = @"";
    if (options.count >= 2) {
        CGFloat optionsMinY = CGFLOAT_MAX;
        for (NSArray *p in options) {
            CGRect f = [(NSValue *)p[2] CGRectValue];
            if (CGRectGetMinY(f) < optionsMinY) optionsMinY = CGRectGetMinY(f);
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
                [t containsString:@"超时"]   || [t containsString:@"红包"] ||
                [t containsString:@"剩余"]   || [t containsString:@"答题时间"]) continue;
            CGRect f = [(NSValue *)p[1] CGRectValue];
            if (CGRectGetMaxY(f) > optionsMinY + 4) continue;
            if (CGRectGetMaxY(f) < optionsMinY - 260) continue;
            if (t.length > qText.length) qText = t;
        }
    }

    // 诊断日志（每 2 秒）
    {
        static NSDate *gLastDiag2 = nil;
        NSDate *now = [NSDate date];
        if (!gLastDiag2 || [now timeIntervalSinceDate:gLastDiag2] > 2.0) {
            gLastDiag2 = now;
            aaLog(@"[诊断] 文字%lu 载体%lu 可点%lu 网页%ld | 有题=%@ 确认=%@ 选项%lu 题干=%@",
                  (unsigned long)all.length, (unsigned long)tappables.count, (unsigned long)options.count,
                  (long)gWebViewCount,
                  hasQuiz ? @"是" : @"否",
                  confirmText.length ? confirmText : (confirm ? @"有" : @"无"),
                  (unsigned long)options.count, qText.length ? qText : @"-");
            if (confirm && options.count < 2) {
                // 找到了确认钮但选项不够 → dump 确认钮上方的所有可点项，便于定位区域问题
                NSMutableArray *dbg = [NSMutableArray array];
                for (NSArray *p in tappables) {
                    if (p.count < 3) continue;
                    if (p[1] == confirm) continue;
                    CGRect f = [(NSValue *)p[2] CGRectValue];
                    if (CGRectGetMaxY(f) > CGRectGetMinY(confirmFrame) + 4) continue;
                    if (CGRectGetMinY(f) < CGRectGetMinY(confirmFrame) - 520) continue;
                    if (dbg.count >= 8) break;
                    [dbg addObject:[NSString stringWithFormat:@"「%@」@(%.0f,%.0f)", p[0],
                                    CGRectGetMinX(f), CGRectGetMinY(f)]];
                }
                aaLog(@"[诊断] 确认钮上方可点项dump：%@", dbg);
            }
            if (hasQuiz && !confirm) {
                static NSDate *gLastDiag3 = nil;
                if (!gLastDiag3 || [now timeIntervalSinceDate:gLastDiag3] > 6.0) {
                    gLastDiag3 = now;
                    // 有答题语境但没找到确认钮 → 列出屏上所有可点文字 + 含关键词文字，定位确认钮/弹窗是否真在
                    NSMutableArray *tps = [NSMutableArray array];
                    for (NSArray *p in tappables) {
                        if (p.count < 3) continue;
                        if (tps.count >= 14) break;
                        [tps addObject:p[0]];
                    }
                    aaLog(@"[诊断] 有题但无确认钮 → 可点文字抽样：%@", tps);
                    NSMutableArray *kws = [NSMutableArray array];
                    NSArray *keys = @[@"确认",@"提交",@"答题",@"红包",@"剩余",@"选择",@"选项",
                                      @"我知道",@"知道了",@"确定",@"交卷",@"抢答"];
                    for (NSArray *p in textFrames) {
                        if (p.count < 3) continue;
                        NSString *tt = p[0];
                        for (NSString *k in keys) if ([tt containsString:k]) { [kws addObject:tt]; break; }
                        if (kws.count >= 14) break;
                    }
                    aaLog(@"[诊断] 含关键词文字：%@", kws);
                }
            }
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

    if (!hasQuiz || !confirm || options.count < 2) return;
    if (all.length < 2) return;

    NSString *qkey = qText;
    if (qText.length == 0) {
        NSMutableArray *ts = [NSMutableArray array];
        for (NSArray *p in options) [ts addObject:p[0]];
        qkey = [ts componentsJoinedByString:@"|"];
    }
    if (![qkey isEqualToString:gLastKey]) {  // 换题了：记快照 + 重置已点记录
        gLastKey = qkey;
        [gDoneQ removeAllObjects];
        NSMutableArray *ots = [NSMutableArray array];
        for (NSArray *p in options) [ots addObject:p[0]];
        aaLog(@"发现新题：「%@」 选项：%@", qText.length ? qText : @"-", ots);
    }
    if ([gDoneQ containsObject:qkey]) return;

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
        // ② 多选：题干含「数字+个/种/项」
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
            // ④ 单选最长（排除肯定句）
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

    // ===== 模拟手速：看题 → 逐个点选项 → 点确认 → 火爆则循环重提 =====
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
    reloadBankIfNeeded();
    gDoneQ = [NSMutableSet set];
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                    repeats:YES
                                      block:^(NSTimer *t){ tick(); }];
    aaLog(@"插件已加载（反向识别版），内置题库 %lu 条\n默认关闭（点悬浮球开启）",
          (unsigned long)(gBank ? gBank.count : 0));
}
