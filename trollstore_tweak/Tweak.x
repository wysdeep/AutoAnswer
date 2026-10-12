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
#import <WebKit/WebKit.h>
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
        m = @[@"以上都是", @"以上都对", @"以上都选", @"以上全选",
              @"以上全对", @"以上全部", @"全部都对", @"全部都是", @"全部都选"];
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
        [textFrames addObject:@[t, [NSValue valueWithCGRect:wf], wnd, view]];
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

// ---------------- 找确认按钮（提交/确认/我知道了/确定…） ----------------
// 注：答题选项为原生 UITextView 控件（非图片、非 WebView），直接读控件树文字即可。
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

// ---------------- 题干「哪2 / 哪3 / 哪4 / 哪两 / 哪三 / 哪四」→ 多选 N ----------------
static NSInteger detectWhichN(NSString *q) {
    if (![q isKindOfClass:[NSString class]] || q.length == 0) return 0;
    NSDictionary *cn = @{@"一":@1, @"二":@2, @"两":@2, @"三":@3, @"四":@4,
                         @"五":@5, @"六":@6, @"七":@7, @"八":@8, @"九":@9, @"十":@10};
    NSRange r = [q rangeOfString:@"哪"];
    if (r.location == NSNotFound) return 0;
    NSUInteger start = r.location + 1;
    NSUInteger end = MIN(start + 3, q.length);      // 只看「哪」后面 3 个字符
    for (NSUInteger i = start; i < end; i++) {
        unichar ch = [q characterAtIndex:i];
        if (ch >= '1' && ch <= '9') return ch - '0';
        NSNumber *v = cn[[q substringWithRange:NSMakeRange(i, 1)]];
        if (v) return v.intValue;
    }
    return 0;
}

// ---------------- 纯数字选项判定（如选项就是 "3" / "4"） ----------------
static BOOL isPureNumber(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || t.length == 0 || t.length > 3) return NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar ch = [t characterAtIndex:i];
        if (ch < '0' || ch > '9') return NO;
    }
    return YES;
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

// ---------------- WebView(H5) 作答路线：与原生并行，谁抓到走谁 ----------------
// 证据矛盾：日志显示屏上有 WKWebView、原生树读不到选项文字；但截图里按钮又像原生。
// 不再二选一，两条路都跑，并把抓到的内容全量写日志，用实测定论。
static void collectWebViews(UIView *v, NSMutableArray *out) {
    if (!v) return;
    Class wk = NSClassFromString(@"WKWebView");
    if (wk && [v isKindOfClass:wk]) {
        WKWebView *wv = (WKWebView *)v;
        if (!wv.isLoading && !wv.hidden && wv.alpha > 0.01 && wv.window) [out addObject:wv];
    }
    for (UIView *c in v.subviews) collectWebViews(c, out);
}

static void webViewRunJS(WKWebView *wv, NSString *js, void (^cb)(NSString *)) {
    @try {
        if (!wv || wv.isLoading || !wv.window) { if (cb) cb(nil); return; }
        [wv evaluateJavaScript:js completionHandler:^(id res, NSError *err){
            if (err) { if (cb) cb(nil); return; }
            if (cb) cb(res ? [NSString stringWithFormat:@"%@", res] : @"");
        }];
    } @catch (NSException *e) {
        if (cb) cb(nil);
    }
}

// ---- AI 配置：Documents/AutoAnswer_config.json，key 不写进代码 ----
static NSString *aaConfigPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"AutoAnswer_config.json"];
}
static NSDictionary *loadAIConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:aaConfigPath()];
    if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![o isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *m = [o mutableCopy];
    // 退役/不推荐的模型名自动纠偏。按 api 域名挑默认模型（三家都有免费额度）：
    //   deepseek      → deepseek-flash        （deepseek-chat/reasoner 已于 2026-07-24 退役）
    //   bigmodel      → glm-4.5-flash         （智谱，免费）
    //   siliconflow   → Qwen/Qwen2.5-7B-Instruct（硅基流动，永久免费模型）
    //   modelscope    → Qwen/Qwen2.5-7B-Instruct（阿里魔搭，免费）
    NSString *mdl = [m[@"model"] isKindOfClass:[NSString class]] ? m[@"model"] : @"";
    NSString *api = [m[@"api"]   isKindOfClass:[NSString class]] ? m[@"api"]   : @"";
    if (mdl.length == 0 ||
        [mdl isEqualToString:@"deepseek-chat"] || [mdl isEqualToString:@"deepseek-reasoner"] ||
        [mdl isEqualToString:@"deepseek-v4-flash"]) {
        NSString *nm = @"deepseek-flash";
        if      ([api containsString:@"bigmodel"])    nm = @"glm-4.5-flash";
        else if ([api containsString:@"siliconflow"])  nm = @"Qwen/Qwen2.5-7B-Instruct";
        else if ([api containsString:@"modelscope"])   nm = @"Qwen/Qwen2.5-7B-Instruct";
        NSString *old = mdl.length ? mdl : @"(空)";
        m[@"model"] = nm;
        @try {
            NSData *nd = [NSJSONSerialization dataWithJSONObject:m
                                                         options:NSJSONWritingPrettyPrinted error:nil];
            if (nd) [nd writeToFile:aaConfigPath() atomically:YES];
        } @catch (NSException *e) {}
        aaLog(@"[配置] 模型名 %@ 已过时/为空 → 已自动改为 %@ 并写回配置文件", old, nm);
    }
    return m;
}
static void ensureConfigFile(void) {
    NSString *p = aaConfigPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return;
    NSDictionary *def = @{@"api":    @"https://api.deepseek.com/chat/completions",
                          @"key":    @"",
                          @"model":  @"deepseek-flash",
                          @"timeout": @1.5};
    NSData *d = [NSJSONSerialization dataWithJSONObject:def
                                                options:NSJSONWritingPrettyPrinted error:nil];
    if (d && [d writeToFile:p atomically:YES])
        aaLog(@"已生成 AI 配置文件（用 Filza 填入 key 后重启淘宝生效）：%@", p);
}

// ---- 自学习缓存：AI 答过的题记下来，下次同样的题 0 毫秒命中，不再联网 ----
static NSString *aaCachePath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"AutoAnswer_cache.json"];
}
static NSMutableDictionary *loadCache(void) {
    NSData *d = [NSData dataWithContentsOfFile:aaCachePath()];
    if (!d) return [NSMutableDictionary dictionary];
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? [o mutableCopy] : [NSMutableDictionary dictionary];
}
static void saveCache(NSMutableDictionary *c) {
    @try {
        if (c.count > 1000) return;
        NSData *d = [NSJSONSerialization dataWithJSONObject:c options:0 error:nil];
        if (d) [d writeToFile:aaCachePath() atomically:YES];
    } @catch (NSException *e) {}
}
static NSString *cacheLookup(NSString *q) {
    @try {
        NSString *nq = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (nq.length == 0) return nil;
        NSDictionary *c = loadCache();
        id v = c[nq];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        if (nq.length >= 6) {                     // 模糊：互相包含（太短不比，防误命中）
            for (NSString *k in c) {
                if (![k isKindOfClass:[NSString class]] || k.length < 6) continue;
                if ([nq containsString:k] || [k containsString:nq]) {
                    id vv = c[k];
                    if ([vv isKindOfClass:[NSString class]] && [vv length]) return vv;
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}
static void cacheRemember(NSString *q, NSString *a) {
    @try {
        NSString *nq = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (nq.length == 0 || a.length == 0) return;
        NSMutableDictionary *c = loadCache();
        c[nq] = a;
        saveCache(c);
    } @catch (NSException *e) {}
}

// ---- 日期题本地规则：选项里挑「未来日期」（严格晚于今天，不含今天）----
// 李佳琦/淘宝这类题的规律：干扰项都是已经过去的日期，正确答案只有一个（或最早一个）未来日期。
// 解析出 yyyymmdd；解析不出返回 0
static int aaParseDate(NSString *s, int curY, int curM, int curD) {
    @try {
        if (!s || s.length == 0) return 0;
        NSRange full = NSMakeRange(0, s.length);
        int y = 0, m = 0, d = 0;
        NSRegularExpression *re = nil;
        NSTextCheckingResult *mm = nil;

        re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]"
                                                       options:0 error:nil];
        mm = [re firstMatchInString:s options:0 range:full];
        if (mm) {
            y = [[s substringWithRange:[mm rangeAtIndex:1]] intValue];
            m = [[s substringWithRange:[mm rangeAtIndex:2]] intValue];
            d = [[s substringWithRange:[mm rangeAtIndex:3]] intValue];
        } else {
            re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]"
                                                           options:0 error:nil];
            mm = [re firstMatchInString:s options:0 range:full];
            if (mm) {
                y = curY;
                m = [[s substringWithRange:[mm rangeAtIndex:1]] intValue];
                d = [[s substringWithRange:[mm rangeAtIndex:2]] intValue];
            } else {
                re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2})\\s*[.\\-/]\\s*(\\d{1,2})(?!\\d)"
                                                               options:0 error:nil];
                mm = [re firstMatchInString:s options:0 range:full];
                if (mm) {
                    y = curY;
                    m = [[s substringWithRange:[mm rangeAtIndex:1]] intValue];
                    d = [[s substringWithRange:[mm rangeAtIndex:2]] intValue];
                }
            }
        }
        if (!y) {                                   // 明天 / 后天 / 大后天
            int add = 0;
            if ([s containsString:@"大后天"])      add = 3;
            else if ([s containsString:@"明天"])   add = 1;
            else if ([s containsString:@"后天"])   add = 2;
            if (add > 0) {
                NSCalendar *cal = [NSCalendar currentCalendar];
                NSDateComponents *dc = [[NSDateComponents alloc] init];
                dc.day = add;
                NSDate *nd = [cal dateByAddingComponents:dc toDate:[NSDate date] options:0];
                NSDateComponents *c2 = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay
                                             fromDate:nd];
                return (int)c2.year * 10000 + (int)c2.month * 100 + (int)c2.day;
            }
            return 0;
        }
        if (m < 1 || m > 12 || d < 1 || d > 31) return 0;
        return y * 10000 + m * 100 + d;
    } @catch (NSException *e) { return 0; }
}

// 命中返回答案文字，不命中返回 nil。注意：日期题答案随时间变，**绝不写缓存**。
static NSString *aaDateRuleAnswer(NSString *question, NSArray *opts) {
    @try {
        if (!opts || opts.count < 2) return nil;
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *c = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay
                                     fromDate:[NSDate date]];
        int curY = (int)c.year, curM = (int)c.month, curD = (int)c.day;
        int today = curY * 10000 + curM * 100 + curD;

        NSMutableArray *future = [NSMutableArray array];    // @[ 文字, yyyymmdd ]
        int dateCnt = 0;
        for (id o in opts) {
            if (![o isKindOfClass:[NSString class]]) continue;
            NSString *t = (NSString *)o;
            int v = aaParseDate(t, curY, curM, curD);
            if (!v) continue;
            dateCnt++;
            if (v > today) [future addObject:@[t, @(v)]];
        }
        // 至少 2 个选项是日期，且日期选项占到一半以上，才认定这是"日期题"（防价格题误判）
        if (dateCnt < 2 || dateCnt * 2 < (int)opts.count) return nil;
        if (future.count == 0) return nil;

        NSArray *sorted = [future sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b){
            int va = [a[1] intValue], vb = [b[1] intValue];
            if (va < vb) return NSOrderedAscending;
            if (va > vb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSString *qs = question ? question : @"";
        BOOL wantEarliest = [qs containsString:@"开始"] || [qs containsString:@"开幕"] ||
                            [qs containsString:@"开抢"] || [qs containsString:@"开售"] ||
                            [qs containsString:@"首发"] || [qs containsString:@"预售"] ||
                            [qs containsString:@"启动"] || [qs containsString:@"上线"] ||
                            [qs containsString:@"首播"] || [qs containsString:@"开播"] ||
                            [qs containsString:@"首场"] || [qs containsString:@"首次"] ||
                            [qs containsString:@"哪天"] || [qs containsString:@"哪一天"];
        BOOL wantLatest   = [qs containsString:@"结束"] || [qs containsString:@"截止"] ||
                            [qs containsString:@"持续到"] || [qs containsString:@"最后一天"];
        NSString *pick, *why;
        if (wantLatest && !wantEarliest) {
            pick = ((NSArray *)sorted.lastObject)[0];
            why  = @"题干含「结束/截止」→ 选最晚的未来日期";
        } else if (wantEarliest) {
            pick = ((NSArray *)sorted.firstObject)[0];
            why  = @"题干含「开始/预售/哪天」→ 选最早的未来日期";
        } else {
            pick = ((NSArray *)sorted[arc4random_uniform((uint32_t)sorted.count)])[0];
            why  = @"题干无时间方向词 → 未来日期里随机";
        }
        NSMutableArray *desc = [NSMutableArray array];
        for (NSArray *a in sorted) [desc addObject:a[0]];
        aaLog(@"[日期规则] 今天 %d-%02d-%02d；%d/%lu 个选项是日期，未来有 %lu 个：%@；%@ → 选「%@」",
              curY, curM, curD, dateCnt, (unsigned long)opts.count,
              (unsigned long)future.count, desc, why, pick);
        return pick;
    } @catch (NSException *e) { aaLog(@"[异常] 日期规则：%@", e); }
    return nil;
}

// ---- 无 AI 时的启发式兜底：不联网、不要题库，比纯随机命中率高一点 ----
// ① 「以上都对 / 以上都是」家族 → 直接选它
// ② 一长三短：最长项明显长于其余 → 选最长
static NSString *aaHeuristicAnswer(NSArray *opts) {
    @try {
        if (!opts || opts.count < 2) return nil;
        for (id o in opts) {
            if (![o isKindOfClass:[NSString class]]) continue;
            NSString *t = (NSString *)o;
            for (NSString *mk in allAboveMarkers())
                if ([t containsString:mk]) { aaLog(@"[启发] 命中「以上都对」家族 → %@", t); return t; }
        }
        NSArray *sorted = [opts sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b){
            if (a.length > b.length) return NSOrderedAscending;
            if (a.length < b.length) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSString *longest = (NSString *)sorted.firstObject;
        NSString *second  = sorted.count > 1 ? (NSString *)sorted[1] : @"";
        if (longest.length >= 6 && longest.length >= second.length * 2) {
            aaLog(@"[启发] 一长三短（最长 %lu 字 vs 次长 %lu 字）→ %@",
                  (unsigned long)longest.length, (unsigned long)second.length, longest);
            return longest;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ---- 联网问答案：返回正确选项的文字；失败/超时返回 nil ----
static void askAI(NSString *question, NSArray *opts, NSDictionary *cfg,
                  void (^cb)(NSString *)) {
    @try {
        NSString *api   = [cfg[@"api"] isKindOfClass:[NSString class]] ? cfg[@"api"] : @"";
        NSString *key   = [cfg[@"key"] isKindOfClass:[NSString class]] ? cfg[@"key"] : @"";
        // 注意：deepseek-chat / deepseek-reasoner 已于 2026-07-24 退役，必须用 deepseek-flash
        NSString *model = [cfg[@"model"] isKindOfClass:[NSString class]] ? cfg[@"model"] : @"deepseek-flash";
        if (api.length == 0 || key.length == 0) { if (cb) cb(nil); return; }

        NSString *optStr = [opts componentsJoinedByString:@"\n"];
        NSString *prompt = [NSString stringWithFormat:
            @"这是直播答题，请只返回正确选项的完整文字，不要解释、不要标点、不要引号、不要选项字母。\n"
            @"如果无法确定，就返回你认为最可能的那一个选项文字。\n题目：%@\n选项：\n%@",
            question, optStr];

        // DeepSeek / 智谱 的 thinking 默认是 enabled(effort=high)，会多花好几秒 —— 抢红包必须显式关掉。
        // 其它平台（硅基流动、魔搭等）不认识这个字段，别乱发，否则可能被拒。
        NSMutableDictionary *body = [@{@"model": model,
                                       @"messages": @[@{@"role": @"user", @"content": prompt}],
                                       @"max_tokens": @32,
                                       @"temperature": @0} mutableCopy];
        if ([api containsString:@"deepseek"] || [api containsString:@"bigmodel"])
            body[@"thinking"] = @{@"type": @"disabled"};
        NSData *bd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        aaLog(@"[AI] 请求 %@（model=%@）", api, model);
        if (!bd) { if (cb) cb(nil); return; }

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:api]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = bd;

        double tmo = [cfg[@"timeout"] respondsToSelector:@selector(doubleValue)]
                   ? [cfg[@"timeout"] doubleValue] : 1.5;
        if (tmo <= 0) tmo = 1.5;
        req.timeoutInterval = tmo + 1.0;

        NSURLSession *s = [NSURLSession sharedSession];
        NSDate *t0 = [NSDate date];
        [[s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
            NSString *ans = nil;
            NSInteger code = 0;
            NSString *raw = @"";
            @try {
                if ([r isKindOfClass:[NSHTTPURLResponse class]]) code = ((NSHTTPURLResponse *)r).statusCode;
                if (d) {
                    raw = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
                    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                    if ([j isKindOfClass:[NSDictionary class]]) {
                        id ch = j[@"choices"];
                        if ([ch isKindOfClass:[NSArray class]] && [ch count] > 0) {
                            id msg = ch[0][@"message"];
                            if ([msg isKindOfClass:[NSDictionary class]] && [msg[@"content"] isKindOfClass:[NSString class]])
                                ans = msg[@"content"];
                        }
                    }
                }
            } @catch (NSException *ex) { ans = nil; }
            if (ans) ans = [ans stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            double cost = [[NSDate date] timeIntervalSinceDate:t0];
            NSString *errDesc = e ? [e localizedDescription] : @"";
            NSString *rawShort = raw.length > 200 ? [raw substringToIndex:200] : raw;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ans.length) {
                    aaLog(@"[AI] 耗时 %.2fs，返回：%@", cost, ans.length > 60 ? [ans substringToIndex:60] : ans);
                } else {
                    aaLog(@"[AI] 失败 耗时 %.2fs｜HTTP=%ld｜err=%@｜body=%@",
                          cost, (long)code, errDesc, rawShort);
                    if (code == 401 || code == 403)      aaLog(@"[AI] → key 填错或没权限，检查 AutoAnswer_config.json 的 key");
                    else if (code == 402)                aaLog(@"[AI] → 余额不足，需要充值或换免费平台");
                    else if (code == 429)                aaLog(@"[AI] → 被限流/免费额度用完，换平台或把 timeout 调大");
                    else if (code >= 400 && code < 500)  aaLog(@"[AI] → 请求被拒，多半是 model 名字不对或该平台没有这个模型");
                }
                if (cb) cb(ans);
            });
        }] resume];
    } @catch (NSException *e) {
        aaLog(@"[异常] askAI：%@", e);
        if (cb) cb(nil);
    }
}

// ---- 组装 JS：doClick=NO 只读题面与选项；doClick=YES 点指定答案(answer 为空则随机)再提交 ----
static NSString *aaQuizJS(BOOL doClick, NSString *answer) {
    NSString *safe = @"";
    if (answer) {
        safe = [answer stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        safe = [safe stringByReplacingOccurrencesOfString:@"'"  withString:@"\\'"];
        safe = [safe stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        safe = [safe stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *head =
        @"(function(){"
        "function txt(e){return (e.innerText||e.textContent||'').trim();}"
        "var all=[].slice.call(document.querySelectorAll('*'));"
        "var cand=[];"
        "all.forEach(function(e){var t=txt(e);if(t&&t.length<=80)cand.push({e:e,t:t});});"
        "var qi=-1,qt='';"
        "cand.forEach(function(c,i){if((c.t.indexOf('？')>=0||c.t.indexOf('?')>=0)&&c.t.length>qt.length){qt=c.t;qi=i;}});"
        "var si=-1;"
        "cand.forEach(function(c,i){if(si<0&&/^(确认提交|提交答案|提交)$/.test(c.t))si=i;});"
        "if(si<0)return JSON.stringify({err:'no-submit'});"
        "var start=qi>=0?qi+1:0,opts=[],seen={};"
        "for(var i=si-1;i>=start;i--){var t=cand[i].t;"
        " if(!t||t.length>30)continue;"
        " if(t.indexOf('\\n')>=0)continue;"
        " if(t===qt)continue;"
        " if(/^\\d+\\s*s$/.test(t))continue;"
        " if(/规则|剩余|答题时间|倒计时|关闭|取消|返回|首页|我知道|提交/.test(t))continue;"
        " if(seen[t])continue;"
        " seen[t]=1;opts.push(cand[i]);}"
        "opts.reverse();"
        "var names=opts.map(function(o){return o.t;});";
    if (!doClick) {
        return [head stringByAppendingString:@"return JSON.stringify({q:qt,opts:names});})()"];
    }
    NSString *tail = [NSString stringWithFormat:
        @"function pt(el){var r=el.getBoundingClientRect();"
        " return [Math.round(r.left+r.width/2),Math.round(r.top+r.height/2)];}"
        "function fire(el){"
        " var c=pt(el),cx=c[0],cy=c[1];"
        " try{var t=new Touch({identifier:1,target:el,clientX:cx,clientY:cy,"
        "  pageX:cx+window.pageXOffset,pageY:cy+window.pageYOffset});"
        "  el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,"
        "   touches:[t],targetTouches:[t],changedTouches:[t]}));"
        "  el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,"
        "   touches:[],targetTouches:[],changedTouches:[t]}));}catch(_){}"
        " try{el.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true,cancelable:true,view:window,"
        "   clientX:cx,clientY:cy,buttons:1}));"
        "  el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,"
        "   clientX:cx,clientY:cy,buttons:1}));"
        "  el.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,cancelable:true,view:window,"
        "   clientX:cx,clientY:cy}));"
        "  el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,"
        "   clientX:cx,clientY:cy}));"
        "  el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,"
        "   clientX:cx,clientY:cy}));}catch(_){}"
        " try{el.click();}catch(_){}"
        "}"
        "var want='%@';"
        "var hit=null;"
        "if(want){opts.forEach(function(o){if(!hit&&(o.t===want||o.t.indexOf(want)>=0||want.indexOf(o.t)>=0))hit=o;});}"
        "if(!hit&&opts.length){hit=opts[Math.floor(Math.random()*opts.length)];}"
        "var clicked=[];"
        "if(hit){try{fire(hit.e);clicked.push(hit.t+'#'+(hit.e.tagName||'?'));}catch(_){}}"
        "return JSON.stringify({q:qt,opts:names,want:want,clicked:clicked});})()", safe];
    return [head stringByAppendingString:tail];
}

// ---- 单独点「确认提交」：重新查 DOM、挑最内层可点元素、强制解除 disabled、补发真实 Touch/Mouse 事件 ----
// mode 0=按钮本体  1=外层容器  2=按钮中心坐标处最顶层元素（真实手指会点到的那个）
static NSString *aaSubmitJS(int mode) {
    return [NSString stringWithFormat:
    @"(function(){"
    "function txt(e){return (e.innerText||e.textContent||'').trim();}"
    "var all=[].slice.call(document.querySelectorAll('*'));"
    "var cand=[];"
    "all.forEach(function(e){var t=txt(e);"
    " if(t&&t.length<=12&&/^(确认提交|提交答案|提交|确认)$/.test(t))cand.push(e);});"
    "if(!cand.length)return JSON.stringify({err:'no-submit',mode:%d});"
    "var btn=null;"
    "for(var i=cand.length-1;i>=0;i--){var tg=(cand[i].tagName||'').toUpperCase();"
    " if(tg==='BUTTON'||tg==='A'){btn=cand[i];break;}}"
    "if(!btn)btn=cand[cand.length-1];"
    "var el=btn,up=0;"
    "if(%d===1){var p=btn.parentElement;"
    " while(p&&p!==document.body&&up<4&&(p.innerText||'').trim().length>40)p=p.parentElement,up++;"
    " if(p)el=p;}"
    "if(%d===2){var r0=btn.getBoundingClientRect();"
    " var hit=document.elementFromPoint(Math.round(r0.left+r0.width/2),Math.round(r0.top+r0.height/2));"
    " if(hit)el=hit;}"
    "var wasDisabled=false;"
    "try{wasDisabled=!!(el.disabled||el.getAttribute('disabled')!==null||el.getAttribute('aria-disabled')==='true');"
    " el.disabled=false;el.removeAttribute('disabled');el.removeAttribute('aria-disabled');"
    " if(el.classList)el.classList.remove('disabled');"
    " var pe=el.parentElement;"
    " if(pe){try{pe.disabled=false;pe.removeAttribute('disabled');"
    "  if(pe.classList)pe.classList.remove('disabled');}catch(_){}}}catch(_){}"
    "var r=el.getBoundingClientRect();"
    "var cx=Math.round(r.left+r.width/2),cy=Math.round(r.top+r.height/2);"
    "try{var t=new Touch({identifier:1,target:el,clientX:cx,clientY:cy,"
    " pageX:cx+window.pageXOffset,pageY:cy+window.pageYOffset});"
    " el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,"
    "  touches:[t],targetTouches:[t],changedTouches:[t]}));"
    " el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,"
    "  touches:[],targetTouches:[],changedTouches:[t]}));}catch(_){}"
    "try{el.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true,cancelable:true,view:window,"
    "  clientX:cx,clientY:cy,buttons:1}));"
    " el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,"
    "  clientX:cx,clientY:cy,buttons:1}));"
    " el.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,cancelable:true,view:window,"
    "  clientX:cx,clientY:cy}));"
    " el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,"
    "  clientX:cx,clientY:cy}));"
    " el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,"
    "  clientX:cx,clientY:cy}));}catch(_){}"
    "var ok='no';try{el.click();ok='clicked';}catch(_){ok='err';}"
    "return JSON.stringify({submit:ok,text:(txt(el)||'').slice(0,20),tag:(el.tagName||''),"
    " wasDisabled:wasDisabled,stillDisabled:!!el.disabled,x:cx,y:cy,up:up,mode:%d});"
    "})()", mode, mode, mode, mode];
}

// ---- 先点选项，隔 0.35s 等页面状态刷新，再点提交；0.8s 后复查，没提交出去就改点外层容器重试 ----
static void answerAndSubmit(WKWebView *wv, NSString *answer, NSString *qkey) {
    webViewRunJS(wv, aaQuizJS(YES, answer), ^(NSString *r){
        aaLog(@"[H5] 选项点击结果：%@", r ? r : @"无返回");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            webViewRunJS(wv, aaSubmitJS(0), ^(NSString *r2){
                aaLog(@"[H5] 提交结果(mode0)：%@", r2 ? r2 : @"无返回");
                // 0.8s 后复查：还在本题就逐级重试 —— 外层容器 → 坐标处最顶层元素
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    webViewRunJS(wv, @"document.body.innerText", ^(NSString *t){
                        BOOL still = t && ([t containsString:@"确认提交"] || [t containsString:@"提交答案"]);
                        if (still && qkey.length == 0) still = NO;                        // 没题干就不乱点
                        if (still && qkey.length && ![t containsString:qkey]) still = NO;  // 已换题别乱点
                        if (!still) { aaLog(@"[H5] 已离开本题 → 提交成功"); return; }
                        aaLog(@"[H5] 提交后仍在本题 → 重试 mode1（外层容器）");
                        webViewRunJS(wv, aaSubmitJS(1), ^(NSString *r3){
                            aaLog(@"[H5] 提交结果(mode1)：%@", r3 ? r3 : @"无返回");
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                webViewRunJS(wv, @"document.body.innerText", ^(NSString *t2){
                                    BOOL s2 = t2 && ([t2 containsString:@"确认提交"] || [t2 containsString:@"提交答案"]);
                                    if (s2 && qkey.length && ![t2 containsString:qkey]) s2 = NO;
                                    if (!s2) { aaLog(@"[H5] 已离开本题 → 提交成功(mode1)"); return; }
                                    aaLog(@"[H5] 仍在本题 → 最后重试 mode2（坐标顶层元素）");
                                    webViewRunJS(wv, aaSubmitJS(2), ^(NSString *r4){
                                        aaLog(@"[H5] 提交结果(mode2)：%@", r4 ? r4 : @"无返回");
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
}

static NSString *gLastWebQ = nil;   // 最近已答过的 H5 题干，用于判重

static void tryWebViewQuiz(void) {
    @try {
        static NSDate *gLastWeb = nil;
        NSDate *now = [NSDate date];
        if (gLastWeb && [now timeIntervalSinceDate:gLastWeb] < 0.8) return;   // 节流
        gLastWeb = now;

        NSMutableArray *wvs = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ((UIWindowScene *)s).windows)
                        if (!w.isHidden && w.alpha > 0.01) collectWebViews(w, wvs);
                }
            }
        }
        if (wvs.count == 0) return;

        for (WKWebView *wv in wvs) {
            webViewRunJS(wv, @"document.body.innerText", ^(NSString *txt){
                if (!txt || txt.length == 0) return;
                BOOL isQuiz = [txt containsString:@"确认提交"] || [txt containsString:@"提交答案"] ||
                              ([txt containsString:@"答题"] &&
                               ([txt containsString:@"剩余"] || [txt containsString:@"提交"]));
                if (!isQuiz) return;
                // 提取题干：含「？」的最长行，作为「同一题」的判重键
                NSString *qKey = @"";
                for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
                    NSString *s = [line stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (([s containsString:@"？"] || [s containsString:@"?"]) && s.length > qKey.length)
                        qKey = s;
                }
                if (qKey.length == 0) qKey = [txt substringToIndex:MIN((NSUInteger)60, txt.length)];

                if (gLastWebQ && [qKey isEqualToString:gLastWebQ]) return;  // 同一题已答过，绝不再点
                gLastWebQ = qKey;

                aaLog(@"[H5] 检测到新题：%@", qKey);
                aaLog(@"[H5] DOM(前 300 字)：%@",
                      txt.length > 300 ? [txt substringToIndex:300] : txt);

                // 第一步：只读题面与选项，先不点
                webViewRunJS(wv, aaQuizJS(NO, nil), ^(NSString *info){
                    NSString *q = qKey;
                    NSArray *opts = nil;
                    if (info) {
                        id j = [NSJSONSerialization JSONObjectWithData:
                                [info dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                        if ([j isKindOfClass:[NSDictionary class]]) {
                            if ([j[@"q"] isKindOfClass:[NSString class]] && [j[@"q"] length]) q = j[@"q"];
                            if ([j[@"opts"] isKindOfClass:[NSArray class]]) opts = j[@"opts"];
                        }
                    }
                    // 兜底：读不到选项 / 没配 key → 直接随机点，绝不空过
                    void (^justRandom)(NSString *) = ^(NSString *why){
                        NSString *h = aaHeuristicAnswer(opts);
                        if (h.length) {
                            aaLog(@"[H5] %@ → 走启发式（非纯随机）", why);
                            answerAndSubmit(wv, h, q);
                        } else {
                            aaLog(@"[H5] %@ → 随机作答", why);
                            answerAndSubmit(wv, nil, q);
                        }
                    };
                    if (!opts || opts.count == 0) { justRandom(@"读不到选项"); return; }

                    // ① 本地日期规则（0ms，不联网）：选项里挑未来日期。
                    //    放在缓存之前 —— 日期题答案随"今天"变化，缓存反而会给出过期答案，所以也不写缓存。
                    NSString *dateAns = aaDateRuleAnswer(q, opts);
                    if (dateAns.length) {
                        aaLog(@"[H5] 走本地日期规则（不联网、不写缓存）");
                        answerAndSubmit(wv, dateAns, q);
                        return;
                    }

                    // ② 本地缓存：命中就 0 毫秒作答，完全不联网
                    NSString *cached = cacheLookup(q);
                    if (cached.length) {
                        aaLog(@"[缓存] 命中（0ms，不联网）：%@ → %@", q, cached);
                        answerAndSubmit(wv, cached, q);
                        return;
                    }

                    NSDictionary *cfg = loadAIConfig();
                    NSString *key = [cfg[@"key"] isKindOfClass:[NSString class]] ? cfg[@"key"] : @"";
                    if (!cfg || key.length == 0) {
                        justRandom([NSString stringWithFormat:@"未配置 AI key（配置文件 %@）", aaConfigPath()]);
                        return;
                    }
                    aaLog(@"[H5] 选项：%@ → 开始问 AI", opts);

                    double tmo = [cfg[@"timeout"] respondsToSelector:@selector(doubleValue)]
                               ? [cfg[@"timeout"] doubleValue] : 1.5;
                    if (tmo <= 0) tmo = 1.5;
                    __block BOOL done = NO;
                    void (^finish)(NSString *) = ^(NSString *ans){
                        if (done) return;
                        done = YES;
                        if (ans.length) {
                            aaLog(@"[AI] 采用答案：%@", ans);
                            cacheRemember(q, ans);      // 记住，下次 0ms
                            aaLog(@"[缓存] 已记住本题，下次遇到直接秒答");
                        }
                        answerAndSubmit(wv, ans, q);
                    };
                    askAI(q, opts, cfg, ^(NSString *ans){ finish(ans); });
                    // 超时兜底：AI 没按时回就立刻随机点，保证不空过
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(tmo * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (done) return;
                        aaLog(@"[AI] %.1fs 超时 → 随机兜底", tmo);
                        finish(nil);
                    });
                });
            });
        }
    } @catch (NSException *e) {
        aaLog(@"[异常] tryWebViewQuiz：%@", e);
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

    // 开关没开也做轻量探测（3s 节流）：屏上出现答题场景就记一条提醒，便于排查"忘了开开关"
    if (!gEnabled) {
        static NSDate *gLastOffDiag = nil;
        NSDate *nowOff = [NSDate date];
        if (!gLastOffDiag || [nowOff timeIntervalSinceDate:gLastOffDiag] > 3.0) {
            gLastOffDiag = nowOff;
            @try {
                NSMutableString *all0 = [NSMutableString string];
                NSMutableArray *t0 = [NSMutableArray array];
                NSMutableArray *f0 = [NSMutableArray array];
                scanScreen(all0, t0, f0);
                for (NSString *k in @[@"答题抢红包", @"确认提交", @"答题超时"]) {
                    if ([all0 containsString:k]) {
                        aaLog(@"[提醒] 屏上有答题场景（含「%@」），但悬浮球是「关」→ 点一下悬浮球变绿才会自动作答", k);
                        break;
                    }
                }
            } @catch (NSException *e) {}
        }
        return;
    }
    if (gWorking) return;
    @try {

    reloadBankIfNeeded();

    NSMutableString *all = [NSMutableString string];
    NSMutableArray *tappables = [NSMutableArray array];
    NSMutableArray *textFrames = [NSMutableArray array];
    scanScreen(all, tappables, textFrames);

    // ===== 空间过滤：只看屏幕中上部「答题弹窗带」，硬排除左下角聊天/弹幕区与顶部状态区 =====
    // 思路：答题弹窗在屏幕中部，聊天窗口在左下角 —— 按坐标切比按文字内容猜更可靠。
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat SW = sb.size.width, SH = sb.size.height;
    NSUInteger tapAll = tappables.count, txtAll = textFrames.count;
    {
        NSMutableArray *tapC = [NSMutableArray array];
        for (NSArray *p in tappables) {
            if (p.count < 3) continue;
            CGRect f = [(NSValue *)p[2] CGRectValue];
            CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
            if (cx < SW * 0.04 || cx > SW * 0.96) continue;
            if (cy < SH * 0.06 || cy > SH * 0.80) continue;   // 去掉底部 20%（聊天区）
            [tapC addObject:p];
        }
        NSMutableArray *txtC = [NSMutableArray array];
        for (NSArray *p in textFrames) {
            if (p.count < 3) continue;
            CGRect f = [(NSValue *)p[1] CGRectValue];
            CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
            if (cx < SW * 0.04 || cx > SW * 0.96) continue;
            if (cy < SH * 0.06 || cy > SH * 0.80) continue;
            [txtC addObject:p];
        }
        [tappables setArray:tapC];
        [textFrames setArray:txtC];
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

    // ===== 答题语境判定：必须出现强信号字样，才认为在答题弹窗 =====
    // 注意：悬浮球按钮自身显示「答题 开」含"答题"二字 → 不能只用"答题"当信号，否则恒为真（假阳性）
    // 这里只用答题弹窗专属词：答题抢红包 / 答题时间 / 剩余(倒计时) / 抢答 / 答题玩法
    BOOL hasQuiz = NO;
    for (NSArray *p in textFrames) {
        if (p.count < 3) continue;
        NSString *tt = p[0];
        if ([tt containsString:@"答题抢红包"] || [tt containsString:@"答题时间"] ||
            [tt containsString:@"剩余"] || [tt containsString:@"抢答"] ||
            [tt containsString:@"倒计时"] || [tt containsString:@"答题玩法"]) { hasQuiz = YES; break; }
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
            aaLog(@"[诊断] 中部区 可点%lu/%lu 文字%lu/%lu | 有题=%@ 确认=%@ 选项%lu 题干=%@",
                  (unsigned long)tappables.count, (unsigned long)tapAll,
                  (unsigned long)textFrames.count, (unsigned long)txtAll,
                  hasQuiz ? @"是" : @"否",
                  confirmText.length ? confirmText : (confirm ? @"有" : @"无"),
                  (unsigned long)options.count, qText.length ? qText : @"-");
            {
                // 中部文字地图：到底中间能不能读到选项，看这一行就够。
                // 平时 8s 打一次省日志；一旦疑似出现答题界面，立刻 1s 打一次，
                // 否则题目只出现几秒会被 8s 节流整场跳过，白测一轮。
                static NSDate *gLastMap = nil;
                BOOL hot = hasQuiz || confirm || options.count >= 2;
                double gap = hot ? 1.0 : 8.0;
                if (!gLastMap || [now timeIntervalSinceDate:gLastMap] > gap) {
                    gLastMap = now;
                    NSMutableArray *m = [NSMutableArray array];
                    for (NSArray *p in textFrames) {
                        if (p.count < 3) continue;
                        if (m.count >= 20) break;
                        CGRect f = [(NSValue *)p[1] CGRectValue];
                        [m addObject:[NSString stringWithFormat:@"「%@」@(%.0f,%.0f)",
                                      p[0], CGRectGetMidX(f), CGRectGetMidY(f)]];
                    }
                    aaLog(@"[地图] 屏中部文字%@：%@", hot ? @"(疑似答题中)" : @"", m);
                }
            }
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
                aaLog(@"[诊断] 原生读不到文字 → 可能：不是淘宝主App / dylib 未注入 / 开关没开");
            }
        }
    }

    // 原生没抓到完整答题界面 → 很可能是 H5/WebView 渲染，改走 JS 路线（两条路并行，不互相排斥）
    BOOL nativeOK = (hasQuiz && confirm && options.count >= 2);
    if (!nativeOK && !gWorking) {
        tryWebViewQuiz();
    }
    if (!nativeOK) return;
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

    // ===== 启发式自动作答（不依赖题库，纯按题面规律判断 单选/多选） =====
    // 规则优先级：
    //   ① 选项含「以上/全部 都对 / 都是 / 都选」→ 直接选它
    //   ② 题干「哪2 / 哪3 / 哪4 / 哪两 / 哪三 / 哪四」→ 多选 N（N ≥ 选项数则全选）
    //   ③ 题干「阿拉伯数字 + 个/种/项」→ 多选 N
    //   ④ 题干有数字（如「三」）但不是「哪N」→ 选项里若有数字 N 与 N+1，两个都选；只有 N 就只选 N
    //   ⑤ 其余（题干无数字）→ 单选：「一长三短」选最长，否则随机选一个
    //   ⑥ 选完统一点下方「确认提交」
    NSMutableArray *optViews = [NSMutableArray array];
    NSMutableArray *optTexts = [NSMutableArray array];

    // ① 「以上/全部都对」家族 → 直接选
    NSMutableArray *allAbove = [NSMutableArray array];
    for (NSArray *p in options) {
        for (NSString *m in allAboveMarkers())
            if ([p[0] containsString:m]) { [allAbove addObject:p]; break; }
    }
    if (allAbove.count > 0) {
        for (NSArray *p in allAbove)
            if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
        aaLog(@"① 命中「以上/全部都对」→ 直接选：%@", optTexts);
    }

    // ② 题干「哪N」→ 多选 N
    if (!optViews.count) {
        NSInteger needN = detectWhichN(qText);
        if (needN > 0) {
            aaLog(@"② 题干含「哪%ld」→ 多选 %ld 个（共 %lu 个选项）",
                  (long)needN, (long)needN, (unsigned long)options.count);
            if (needN >= (NSInteger)options.count) {
                for (NSArray *p in options)
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
            } else {
                NSMutableArray *pool = [NSMutableArray arrayWithArray:options];
                while (optViews.count < needN && pool.count) {
                    NSUInteger idx = arc4random_uniform((uint32_t)pool.count);
                    NSArray *p = pool[idx];
                    [pool removeObjectAtIndex:idx];
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
                }
            }
        }
    }

    // ③ 题干「阿拉伯数字 + 个/种/项」→ 多选 N
    if (!optViews.count) {
        NSInteger best = 0;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d)\\s*[个种项]"
                                                                              options:0 error:nil];
        NSArray *ms = [re matchesInString:qText options:0 range:NSMakeRange(0, qText.length)];
        for (NSTextCheckingResult *m in ms) {
            NSInteger d = [[qText substringWithRange:[m rangeAtIndex:1]] integerValue];
            if (d == 4) { best = 4; break; }
            if (d == 3 && best < 3) best = 3;
            if (d == 2 && best < 2) best = 2;
        }
        if (best > 0) {
            aaLog(@"③ 题干含「%ld + 个/种/项」→ 多选 %ld 个", (long)best, (long)best);
            if (best >= (NSInteger)options.count) {
                for (NSArray *p in options)
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
            } else {
                NSMutableArray *pool = [NSMutableArray arrayWithArray:options];
                while (optViews.count < best && pool.count) {
                    NSUInteger idx = arc4random_uniform((uint32_t)pool.count);
                    NSArray *p = pool[idx];
                    [pool removeObjectAtIndex:idx];
                    if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
                }
            }
        }
    }

    // ④ 题干有数字但不是「哪N」→ 选项里有数字 N 与 N+1 就两个都选；只有 N 就只选 N
    if (!optViews.count) {
        NSInteger n = firstNumeralIn(qText);
        if (n > 0) {
            NSMutableArray *numOpt = [NSMutableArray array];
            for (NSArray *p in options) if (isPureNumber(p[0])) [numOpt addObject:p];
            NSArray *hitN = nil, *hitN1 = nil;
            for (NSArray *p in numOpt) {
                if (!hitN  && [p[0] intValue] == n)     hitN  = p;
                if (!hitN1 && [p[0] intValue] == n + 1) hitN1 = p;
            }
            if (hitN && hitN1) {
                [optViews addObject:hitN[1]];  [optTexts addObject:hitN[0]];
                [optViews addObject:hitN1[1]]; [optTexts addObject:hitN1[0]];
                aaLog(@"④ 题干含数字 %ld（非「哪N」）→ 选项里有 %ld 和 %ld → 两个都选",
                      (long)n, (long)n, (long)(n + 1));
            } else if (hitN) {
                [optViews addObject:hitN[1]]; [optTexts addObject:hitN[0]];
                aaLog(@"④ 题干含数字 %ld → 选对应数字项：%@", (long)n, hitN[0]);
            }
        }
    }

    // ⑤ 其余 → 单选：「一长三短」选最长，否则随机
    if (!optViews.count) {
        BOOL oneLong = NO;
        if (options.count >= 3) {
            NSMutableArray *lens = [NSMutableArray array];
            for (NSArray *p in options) [lens addObject:@([p[0] length])];
            NSArray *sorted = [lens sortedArrayUsingSelector:@selector(compare:)];
            NSUInteger maxLen = [sorted.lastObject unsignedIntegerValue];
            NSUInteger second = [sorted[sorted.count - 2] unsignedIntegerValue];
            if (second > 0 && maxLen >= second * 2) oneLong = YES;   // 最长 ≥ 次长×2 才算「一长三短」
        }
        if (oneLong) {
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
            aaLog(@"⑤ 单选「一长三短」→ 选最长：%@", bestText ?: @"");
        }
        if (!optViews.count) {
            NSArray *p = options[arc4random_uniform((uint32_t)options.count)];
            [optViews addObject:p[1]]; [optTexts addObject:p[0]];
            aaLog(@"⑤ 题干无数字 → 单选随机：%@", p[0]);
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
    ensureConfigFile();
    gDoneQ = [NSMutableSet set];
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                    repeats:YES
                                      block:^(NSTimer *t){ tick(); }];
    aaLog(@"插件已加载（题面规则作答：以上都对直接选 / 哪N多选 / 数字+个种项多选 / 数字3和4 / 一长三短选最长 / 无数字随机）\n默认关闭（点悬浮球开启）");
}
