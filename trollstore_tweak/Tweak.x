// Tweak.x — 淘宝直播间「答题抢红包」自动作答插件（TrollStore / TrollFools 注入版）
//
// 功能：
//   1. 悬浮球手动开关（默认关，点一下切换 开/关）——不会上来就自动跑，由你控制时机
//   2. 读题（视图树取文字，无 OCR）→ 本地题库匹配 → 模拟手速点选选项
//   3. 多选题自动依次点多个选项（间隔随机）
//   4. 选项点完自动点「确认提交」
//   5. 全程随机延迟模拟真人，降低风控特征
//   6. 【新】屏幕出现「以上都是 / 以上都对…」选项时，默认必选该项
//   7. 【新】题库可随时编辑：app 沙盒 Documents/AutoAnswer_questions.json，改完 0.2s 内热更新，无需重装
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
static NSDate   *gExternalMtime = nil;  // 外部题库最后加载时间

static double rnd(double a, double b) {
    return a + ((double)arc4random_uniform(10000) / 10000.0) * (b - a);
}

static void updateToggleUI(void);

// ---------------- 悬浮开关按钮 ----------------
@interface AutoAnswerBundle : NSObject @end
@implementation AutoAnswerBundle
+ (void)toggleTapped {
    gEnabled = !gEnabled;
    updateToggleUI();
    NSLog(@"[AutoAnswer] 手动开关 → %@", gEnabled ? @"开" : @"关");
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
    if (path) {
        NSArray *arr = loadBankFromPath(path);
        if (arr) gBank = arr;
    }
    // 可编辑题库路径：app 沙盒 Documents/AutoAnswer_questions.json
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject;
    gExternalPath = [dir stringByAppendingPathComponent:@"AutoAnswer_questions.json"];
}

// 题库热更新：外部文件优先于内置；改了文件下一次轮询（0.2s）自动生效，无需重装 dylib
static void reloadBankIfNeeded(void) {
    if (!gExternalPath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:gExternalPath];
    if (!exists) {
        // 首次：把内置题库复制出来，作为你之后可随时编辑的文件（见 README「加题库」）
        NSArray *base = gBank ?: @[];
        NSData *d = [NSJSONSerialization dataWithJSONObject:base
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:nil];
        if (d && [d writeToFile:gExternalPath atomically:YES]) {
            NSDictionary *attr = [fm attributesOfItemAtPath:gExternalPath error:nil];
            gExternalMtime = attr[NSFileModificationDate];
            NSLog(@"[AutoAnswer] 已生成可编辑题库（照这个格式加题即可）：%@", gExternalPath);
        }
        return;
    }
    NSDictionary *attr = [fm attributesOfItemAtPath:gExternalPath error:nil];
    NSDate *mtime = attr[NSFileModificationDate];
    if (!gExternalMtime || [mtime compare:gExternalMtime] == NSOrderedDescending) {
        NSArray *ext = loadBankFromPath(gExternalPath);
        if (ext) {
            gBank = ext;
            gExternalMtime = mtime;
            NSLog(@"[AutoAnswer] 题库热更新生效：%lu 条", (unsigned long)gBank.count);
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

// ---------------- 点击 ----------------
static void tapView(UIView *view) {
    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
            id target = nil;
            SEL action = NULL;
            object_getInstanceVariable(g, "_target", (void **)&target);
            object_getInstanceVariable(g, "_action", (void **)&action);
            if (target && action) {
                ((void(*)(id, SEL, id))objc_msgSend)(target, action, g);
                return;
            }
        }
    }
    // 兜底：命中测试到子视图再试
    CGRect r = view.bounds;
    UIView *hit = [view hitTest:CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)) withEvent:nil];
    if (hit && hit != view) tapView(hit);
}

// ---------------- 主循环 ----------------
static void tick(void) {
    if (!gEnabled || gWorking || gBank.count == 0) return;

    // 题库热更新（每轮询检查一次外部文件，改了立即生效）
    reloadBankIfNeeded();

    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)s).windows)
                    if (w.isKeyWindow) { win = w; break; }
            }
        }
    } else {
        win = UIApplication.sharedApplication.keyWindow;
    }
    if (!win) return;

    // 悬浮球懒创建（等 scene 就绪）
    if (!gOverlay) {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
        createOverlay(sc);
    }

    NSMutableString *all = [NSMutableString string];
    NSMutableArray *tappables = [NSMutableArray array];
    collectViews(win, all, tappables);
    if (all.length < 2) return;

    NSString *qkey = questionKey(all);
    if (!qkey) return;                       // 屏上没有题目，不动作
    if (![qkey isEqualToString:gLastKey]) {  // 换题了，重置已点记录
        gLastKey = qkey;
        [gDoneQ removeAllObjects];
    }
    if ([gDoneQ containsObject:qkey]) return; // 这道题已经处理过，不重复点（防重复提交）

    // === 新特性①：屏幕出现「以上都是」则默认必选 ===
    NSArray *allAbove = findAllAboveTappables(tappables);

    NSArray *answers = matchAnswers(all);

    NSMutableArray *optViews = [NSMutableArray array];
    NSMutableArray *optTexts = [NSMutableArray array];

    if (allAbove.count > 0) {
        // 默认必选：只点「以上都是」这一项（不再叠加题库其他答案，避免重复点击互相取消）
        for (NSArray *p in allAbove) {
            if (![optTexts containsObject:p[0]]) {
                [optViews addObject:p[1]];
                [optTexts addObject:p[0]];
            }
        }
        NSLog(@"[AutoAnswer] 命中「以上都是」默认必选，共 %lu 项", (unsigned long)optViews.count);
    } else {
        if (!answers.count || answers.count > 4) return;
        for (NSString *ans in answers) {
            for (NSArray *p in tappables) {
                NSString *t = p[0];
                if ([t isEqualToString:ans] || [t containsString:ans]) {
                    if (![optTexts containsObject:t]) {
                        [optViews addObject:p[1]];
                        [optTexts addObject:t];
                    }
                    break;
                }
            }
        }
    }
    if (!optViews.count) return;
    UIView *confirm = findConfirmButton(tappables);

    // ===== 模拟手速：看题 → 逐个点选项（随机间隔）→ 点确认提交 =====
    gWorking = YES;
    [gDoneQ addObject:qkey];
    double reading = rnd(kReadingMin, kReadingMax);
    NSLog(@"[AutoAnswer] 命中 %@，看题 %.1fs", optTexts, reading);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(reading * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        double offset = 0;
        for (NSUInteger i = 0; i < optViews.count; i++) {
            if (i > 0) offset += rnd(kOptionGapMin, kOptionGapMax);
            UIView *v = optViews[i];
            NSString *txt = optTexts[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(offset * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                tapView(v);
                NSLog(@"[AutoAnswer] 已选：%@", txt);
            });
        }
        double confirmAt = offset + rnd(kConfirmMin, kConfirmMax);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(confirmAt * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (confirm) {
                tapView(confirm);
                NSLog(@"[AutoAnswer] 已点「确认提交」");
            } else {
                NSLog(@"[AutoAnswer] 未找到确认按钮，跳过提交");
            }
            gWorking = NO;
        });
    });
}

%ctor {
    loadBank();
    reloadBankIfNeeded();   // 首次启动把内置题库复制成可编辑文件，方便你随时加题
    gDoneQ = [NSMutableSet set];
    dispatch_async(dispatch_get_main_queue(), ^{ /* 悬浮球在 tick 里懒创建 */ });
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                    repeats:YES
                                      block:^(NSTimer *t){ tick(); }];
    NSLog(@"[AutoAnswer] 插件已加载，内置题库 %lu 条\n可编辑题库路径：%@\n默认关闭（点悬浮球开启）",
          (unsigned long)(gBank ? gBank.count : 0), gExternalPath);
}
