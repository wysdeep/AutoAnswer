// Tweak.x — 淘宝直播间「答题抢红包」自动作答插件（TrollStore / TrollFools 注入版）
//
// 功能：
//   1. 悬浮球手动开关（默认关，点一下切换 开/关）——不会上来就自动跑，由你控制时机
//   2. 读题（视图树取文字，无 OCR）→ 启发式自动选（不依赖题库，按界面文字规律）
//   3. 单选：出现「以上都是/以上都对」必选该项；否则选文字最长的选项（排除肯定句陷阱）
//   4. 多选：题面出现「数字+个/种/项」才是多选——看到4全选、3随机选3、2随机选2；无数字一律单选
//   5. 选项点完自动点「确认提交」；若提示「火爆/繁忙/失败」则循环重提直至成功
//   6. 全程随机延迟模拟真人，降低风控特征
//   7. 题库仍可在 Documents/AutoAnswer_questions.json 编辑，但已非必须（启发式优先）
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
static const double kConfirmMin   = 0.20; // 选完到点「确认提交」
static const double kConfirmMax   = 0.30;
// 抢红包场景：答题窗口约 7s，但要在 ~2s 内答完。最坏（3 选项多选）：
// 0.2 + 2×0.3 + 0.3 = 1.1s，加轮询检测 0.2s ≈ 1.3s，余量充足；单选取更快 ~0.5s。

static NSString * const kConfirmText = @"提交";

// 「以上都是 / 以上都对 / 以上都选 / 以上全选」家族——屏幕出现则默认必选
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
static NSMutableSet *gDoneQ = nil;    // 当前题已点过的选项
static NSString *gLastKey = nil;      // 当前题标识
static UIWindow *gOverlay = nil;
static UIButton *gToggleBtn = nil;

// 可编辑题库（运行时热更新，无需重装 dylib）
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
    // 可编辑题库路径：app 沙盒 Documents/AutoAnswer_questions.json
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

// 【自动导入】把内置 questions.json 的新题自动合并进外部可编辑文件：
// - 外部文件不存在时，直接用内置题库生成它；
// - 外部已有时，把内置里「外部没有」的题补进去，外部你自己加的题不会被覆盖。
// 这样日常加题 = 在电脑上改内置 questions.json → 重跑构建 → 重装，新题自动生效，无需进 Filza。
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

// 题库热更新：外部文件优先于内置；改了文件下一次轮询（0.2s）自动生效，无需重装 dylib
static void reloadBankIfNeeded(void) {
    if (!gExternalPath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:gExternalPath];
    if (!exists) {
        // 首次：先把内置题库写成外部可编辑文件（见 README「加题库」）
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
    // 内置题库可能比外部新（重装了新版 dylib 或重跑构建）→ 自动合并新题
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

// ---------------- 收集：全部文字（匹配用）+ 可点目标（点击用） ----------------
static void collectViews(UIView *view, NSMutableString *allTexts, NSMutableArray *tappables) {
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
        UIView *target = findTapTarget(view);
        if (target) [tappables addObject:@[t, target]];
    }
    for (UIView *c in view.subviews) collectViews(c, allTexts, tappables);
}

// ---------------- 网页视图检测（诊断用） ----------------
// 若原生读不到文字但屏上有 WebView，则答题界面很可能是网页渲染，原生 UILabel 读不到。
static NSInteger gWebViewCount = 0;
static void scanWebViews(UIView *v) {
    if (!v) return;
    Class wk  = NSClassFromString(@"WKWebView");
    Class uiw = NSClassFromString(@"UIWebView");
    if ((wk  && [v isKindOfClass:wk])  || (uiw && [v isKindOfClass:uiw])) gWebViewCount++;
    for (UIView *c in v.subviews) scanWebViews(c);
}
// 注意：早期版本曾在此对屏上每个 WKWebView 自动跑 evaluateJavaScript 读 DOM，
// 会在淘宝主页大量 WebView 未就绪时导致 App 闪退，已移除。WebView 读取方案改为
// 仅在确认题目出现后、且用 @try/@catch 包裹时再谨慎调用。

// ---------------- 题库匹配（答案必须出现在界面 + 关键词命中） ----------------
// 返回需要点击的选项文字数组（多选返回多个）
static NSArray<NSString *> *matchAnswers(NSString *combined) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *e in gBank) {
        NSArray *ansList = nil;
        id a = e[@"a"];
        if ([a isKindOfClass:[NSString class]])     ansList = @[a];
        else if ([a isKindOfClass:[NSArray class]]) ansList = a;
        if (!ansList.count) continue;

        BOOL triggered = NO;
        NSString *q = e[@"q"];
        if ([q isKindOfClass:[NSString class]] && q.length && [combined containsString:q])
            triggered = YES;
        if (!triggered) {
            NSArray *kw = e[@"kw"];
            if ([kw isKindOfClass:[NSArray class]]) {
                for (NSString *k in kw) {
                    if ([k isKindOfClass:[NSString class]] && k.length && [combined containsString:k]) {
                        triggered = YES; break;
                    }
                }
            }
        }
        if (!triggered) continue;

        for (NSString *ans in ansList)
            if ([ans isKindOfClass:[NSString class]] && ans.length && [combined containsString:ans])
                [result addObject:ans];
    }
    return result;
}

// ---------------- 「以上都是」默认必选 ----------------
// 屏幕选项里只要出现「以上都是 / 以上都对 / 以上都选 / 以上全选」，必定点它
static NSArray *findAllAboveTappables(NSArray *tappables) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *p in tappables) {
        NSString *t = p[0];
        for (NSString *m in allAboveMarkers()) {
            if (t.length && [t containsString:m]) { [out addObject:p]; break; }
        }
    }
    return out;
}

// ---------------- 找「确认提交」按钮 ----------------
static UIView *findConfirmButton(NSArray *tappables) {
    for (NSArray *p in tappables) {
        NSString *t = p[0];
        if ([t containsString:kConfirmText] && t.length <= 8) return p[1];
    }
    return nil;
}

// ---------------- 肯定句判定（单选题里这类多为陷阱，不选） ----------------
static BOOL isAffirmativeSentence(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || t.length == 0) return NO;
    // 绝对化/送分型陈述：命中且像"一句话"时才视为肯定句，避免误杀短术语答案
    NSArray *markers = @[@"确实",@"当然",@"肯定",@"毫无疑问",@"没错",@"是的",
                         @"对，",@"就是这样",@"一定",@"绝对",@"毫无疑问地"];
    for (NSString *m in markers)
        if ([t containsString:m] && (t.length > 8 || [t containsString:@"。"])) return YES;
    return NO;
}

// ---------------- 题目标识（取带问号的最长文本） ----------------
static NSString *questionKey(NSString *combined) {
    NSString *best = nil;
    for (NSString *line in [combined componentsSeparatedByString:@"\n"]) {
        if (line.length < 4) continue;
        if ([line containsString:@"？"] || [line containsString:@"?"]) {
            if (!best || line.length > best.length) best = line;
        }
    }
    return best;
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
                // 用 object_getIvar 安全取值，避免手动算偏移解引用野指针
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
// 用普通 C 函数递归（避免 block 自捕获导致的 retain cycle）
static void retrySubmitIfBusy(UIView *confirm, NSInteger left) {
    @try {
        NSMutableString *all2 = [NSMutableString string];
        NSMutableArray *tap2 = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ((UIWindowScene *)s).windows)
                        if (!w.isHidden && w.alpha > 0.01) collectViews(w, all2, tap2);
                }
            }
        }
        BOOL busy = NO;
        for (NSString *k in @[@"火爆",@"繁忙",@"失败",@"稍后",@"重试",@"超时",@"抢不到",@"人太多",@"网络"]) {
            if ([all2 containsString:k]) { busy = YES; break; }
        }
        UIView *confirm2 = findConfirmButton(tap2);
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
    // 悬浮球懒创建：必须放在所有提前 return 之前（无条件创建），
    // 否则默认关闭时 tick 直接 return，浮钮永远建不出来（鸡生蛋死锁）
    if (!gOverlay) {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
        createOverlay(sc);
    }

    if (!gEnabled || gWorking) return;
    @try {

    // 题库热更新（每轮询检查一次外部文件，改了立即生效）
    reloadBankIfNeeded();

    // 收集前台场景里【所有 window】的文字与可点目标（答题浮层可能在非 keyWindow）
    NSMutableString *all = [NSMutableString string];
    NSMutableArray *tappables = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)s).windows)
                    if (!w.isHidden && w.alpha > 0.01) collectViews(w, all, tappables);
            }
        }
    } else {
        collectViews(UIApplication.sharedApplication.keyWindow, all, tappables);
    }

    // 统计屏上网页视图数量（诊断：用来判断答题界面是不是 WebView 渲染）
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

    // 诊断日志（开启时每 2 秒一条，无条件必打）
    {
        static NSDate *gLastDiag2 = nil;
        NSDate *now = [NSDate date];
        if (!gLastDiag2 || [now timeIntervalSinceDate:gLastDiag2] > 2.0) {
            gLastDiag2 = now;
            BOOL hasQ = NO;
            for (NSString *ln in [all componentsSeparatedByString:@"\n"])
                if ([ln containsString:@"？"] || [ln containsString:@"?"]) { hasQ = YES; break; }
            aaLog(@"[诊断] 浮钮=%@ 开关=%@ 原生文字 %lu 字符 / 可点 %lu / 网页视图 %ld / 有问号=%@",
                  gOverlay?@"有":@"无", gEnabled?@"开":@"关",
                  (unsigned long)all.length, (unsigned long)tappables.count,
                  (long)gWebViewCount, hasQ?@"是":@"否");
            if (all.length < 2) {
                if (gWebViewCount > 0) {
                    aaLog(@"[诊断] 原生读不到文字但屏上有 %ld 个网页视图 → 强烈怀疑答题界面是网页(WebView)渲染，原生 UILabel 读不到文字",
                          (long)gWebViewCount);
                } else {
                    aaLog(@"[诊断] 原生读不到文字且无网页视图 → 可能：不是淘宝主App / dylib 未注入 / 答题页不在前台 / 开关没开");
                }
            }
        }
    }

    if (all.length < 2) return;

    NSArray *answers = matchAnswers(all);
    NSArray *allAbove = findAllAboveTappables(tappables);

    NSString *qkey = questionKey(all);
    if (!qkey) {
        // 屏上没问号：只要题库命中或遇到「以上都是」，仍视为有题，用答案串作题key兜底去重
        if (answers.count || allAbove.count)
            qkey = [NSString stringWithFormat:@"A:%@|AB:%lu",
                    [answers componentsJoinedByString:@","], (unsigned long)allAbove.count];
        else
            return;                           // 屏上既无问号也无命中，不动作
    }
    if (![qkey isEqualToString:gLastKey]) {  // 换题了，重置已点记录
        gLastKey = qkey;
        [gDoneQ removeAllObjects];
    }
    if ([gDoneQ containsObject:qkey]) return; // 这道题已经处理过，不重复点（防重复提交）

    // ===== 启发式自动作答（不依赖题库，按界面文字规律选） =====
    UIView *confirm = findConfirmButton(tappables);

    // 1) 收集"候选选项"：所有可点项，去掉确认按钮、悬浮球、常见非选项按钮
    static NSArray *nonOptionWords = nil;
    static dispatch_once_t onceNon;
    dispatch_once(&onceNon, ^{
        nonOptionWords = @[@"返回",@"关闭",@"首页",@"我的",@"购物车",@"分享",@"举报",@"客服",
                           @"下一题",@"上一题",@"跳过",@"换一换",@"更多",@"知道了",@"确定",@"取消"];
    });
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSArray *p in tappables) {
        if (p.count < 2) continue;
        if (p[1] == confirm) continue;
        if (gToggleBtn && p[1] == gToggleBtn) continue;
        NSString *t = p[0];
        BOOL skip = NO;
        for (NSString *w in nonOptionWords) if ([t containsString:w]) { skip = YES; break; }
        if (skip) continue;
        [candidates addObject:p];
    }

    // 2) 题型识别：题面出现「数字+个/种/项」才是多选
    //    看到 4 → 全选；看到 3 → 随机选3；看到 2 → 随机选2；没有数字 → 一律单选
    BOOL isMulti = NO; NSInteger needN = 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d)\\s*[个种项]"
                                                                          options:0 error:nil];
    NSArray *ms = [re matchesInString:all options:0 range:NSMakeRange(0, all.length)];
    NSInteger best = 0;
    for (NSTextCheckingResult *m in ms) {
        NSInteger d = [[all substringWithRange:[m rangeAtIndex:1]] integerValue];
        if (d == 4) { best = 4; break; }      // 4 最高优先：全选
        if (d == 3 && best < 3) best = 3;
        if (d == 2 && best < 2) best = 2;
    }
    if (best > 0) { isMulti = YES; needN = best; }

    NSMutableArray *optViews = [NSMutableArray array];
    NSMutableArray *optTexts = [NSMutableArray array];

    if (allAbove.count > 0) {
        // 「以上都是 / 以上都对」家族：无论单多选都优先必选
        for (NSArray *p in allAbove) {
            if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
        }
        aaLog(@"命中「以上都是」默认必选，共 %lu 项", (unsigned long)optViews.count);
    } else if (isMulti) {
        NSMutableArray *pool = [NSMutableArray arrayWithArray:candidates];
        if (needN <= 0 || needN >= (NSInteger)pool.count) {
            for (NSArray *p in pool) {
                if (![optTexts containsObject:p[0]]) { [optViews addObject:p[1]]; [optTexts addObject:p[0]]; }
            }
            aaLog(@"多选：全选 %lu 项（needN=%ld, 选项数=%lu）", (unsigned long)optViews.count, (long)needN, (unsigned long)pool.count);
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
        // 单选：选文字最长项（排除肯定句；全被排除则退化选最长）
        NSString *bestText = nil; UIView *bestView = nil; NSUInteger bestLen = 0;
        for (NSArray *p in candidates) {
            NSString *t = p[0];
            if (isAffirmativeSentence(t)) continue;
            NSUInteger L = t.length;
            if (L > bestLen) { bestLen = L; bestText = t; bestView = p[1]; }
        }
        if (!bestView) {
            for (NSArray *p in candidates) {
                NSString *t0 = p[0];
                NSUInteger L = t0.length;
                if (L > bestLen) { bestLen = L; bestText = t0; bestView = p[1]; }
            }
        }
        if (bestView) { [optViews addObject:bestView]; [optTexts addObject:bestText]; }
        aaLog(@"单选：选最长项（%lu 字符）%@", (unsigned long)bestLen, bestText ?: @"");
    }

    if (!optViews.count) return;

    // ===== 模拟手速：看题 → 逐个点选项（随机间隔）→ 点确认提交 → 火爆则循环重提 =====
    gWorking = YES;
    [gDoneQ addObject:qkey];
    double reading = rnd(kReadingMin, kReadingMax);
    aaLog(@"作答 %@，看题 %.1fs", optTexts, reading);

    void (^doSubmit)(void) = ^{
        if (confirm) { tapView(confirm); aaLog(@"已点「确认提交」"); }
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
    reloadBankIfNeeded();   // 首次启动把内置题库复制成可编辑文件，方便你随时加题
    gDoneQ = [NSMutableSet set];
    dispatch_async(dispatch_get_main_queue(), ^{ /* 悬浮球在 tick 里懒创建 */ });
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                    repeats:YES
                                      block:^(NSTimer *t){ tick(); }];
    aaLog(@"插件已加载，内置题库 %lu 条\n可编辑题库路径：%@\n默认关闭（点悬浮球开启）",
          (unsigned long)(gBank ? gBank.count : 0), gExternalPath);
}
