# 巨魔（TrollStore）可注入的淘宝直播答题自动点击插件

进程内 dylib 方案：无需 Mac 常驻、无需 WDA、无需 7 天重签。注入后在**手机淘宝**进程内
直接遍历视图树读文字、比对题库、触发选项点击 + 自动点「确认提交」——和安卓无障碍方案完全
对等，**不用 OCR**。

目标场景：李佳琦直播间「答题抢红包」（每晚约 7 题，每题答题窗口约 7 秒，超时 21 秒）。

## 核心行为（已按你的要求实现）

1. **手动开关（悬浮球）默认关闭**：插件加载后不自动跑，屏幕左上角出现一个圆形浮球
   「答题 / 关」。你点一下切到「开」才开始自动作答；再点一下关闭。可自己决定开启时机
   （手动开，或配合系统快捷指令定时开/关）。
2. **自动选题 + 自动提交**：题库命中后，模拟手速点选正确选项（多选依次点多个），
   选完自动点屏幕下方的「确认提交 / 提交」按钮。
3. **模拟手动速度（抢红包要快，按你的要求调过）**：全程随机延迟——
   - 看题 0.10~0.20 秒；
   - 多选每两个选项之间间隔 0.20~0.30 秒；
   - 选完后停顿 0.20~0.30 秒再点「确认提交」。
   7 秒答题窗口内最坏（3 选项多选）约 0.2 + 2×0.3 + 0.3 = 1.1 秒，加轮询检测 0.2 秒
   ≈ 1.3 秒答完，余量充足；单选题更快（约 0.5 秒）。若想更接近 2 秒上限，把 `Tweak.x`
   顶部的 `kReading*/kOptionGap*/kConfirm*` 调大即可。
4. **只点真选项，不误点题干**：点击目标仅限 `UIControl` 或带点按手势的视图，题干
   Label 永远不可点；答案文字必须真实出现在当前界面才点，绝不盲点。
5. **按题去重**：同一道题只作答一次，不重复提交。
6. **「以上都是」默认必选**：只要当前选项里出现「以上都是 / 以上都对 / 以上都选 / 以上全选」，
   插件会**无条件直接点它**（不再查题库），这是李佳琦答题里常见的「全选」套路。
7. **题库随时可加（热更新）**：插件首次启动会把内置 `questions.json` 复制成
   `AutoAnswer_questions.json` 放在 App 沙盒 Documents，你之后直接改这个文件、保存，
   下一次扫描（0.2 秒）就生效，**不用重装、不用重编译**。详见下方「加题库」。

## 前置条件（设备端）

1. 设备已装 **TrollStore**（依赖对应 iOS 版本的 CoreTrust 漏洞，如 kfd / Dopamine 支持的范围）。
2. 已装 **TrollFools**（或用 TrollStore 自带的注入方式），用于把 dylib 注进 App。
3. 一台 **Mac** 装好 **Theos + ellekit** 工具链（仅编译 dylib 时需要，编译完 Mac 就不必常驻）。

## 编译（Mac 上）

**一键方式**（已附 `build.sh`）：

```bash
cd trollstore_tweak
bash build.sh     # 需要本机已装 Theos + ellekit
```

**或手动**：

```bash
export THEOS=~/theos
make            # 产出 .theos/obj/AutoAnswer.dylib，资源含 questions.json
```

> 编译产物 `AutoAnswer.dylib` 与 `questions.json` 需一并注入/嵌入到淘宝 App。
> 本机（Windows）无法编译 iOS dylib，必须在 macOS 上完成这一步。

## 没有 Mac？用 GitHub Actions 云端编译（免费，推荐）

你不需要任何电脑装 Xcode。GitHub 提供免费的 macOS 云主机，自动装 Theos+ellekit 并编译，
产物直接下载。已配好 workflow：`.github/workflows/build.yml`（用 `Randomblock1/theos-action`）。

**步骤（全程网页操作，不用装 git）：**
1. 打开 https://github.com → New repository → 仓库名随意（如 `AutoAnswer`），选 **Public**（公开仓库 macOS 分钟免费），创建。
2. 把本包的 `trollstore_tweak/` 文件夹和 `.github/` 文件夹一起拖进仓库（GitHub 网页支持拖文件夹），Commit。
3. 进仓库 **Actions** 页 → 左侧 `Build AutoAnswer dylib` → **Run workflow** → 跑约 2~3 分钟。
4. 跑完下方 **Artifacts** 里下载 `AutoAnswer-dylib`（含 `AutoAnswer.dylib` + `questions.json`）。
5. 拿这俩文件走下面的「注入与安装」。

> 若构建报错说找不到 ellekit/SDK，多半是 SDK 版本，把 `Makefile` 里
> `TARGET := iphone:clang:16.5:15.0` 的 `16.5` 改成 `latest` 或你设备对应的版本再重跑。

## 注入与安装（设备上）

1. 把 `AutoAnswer.dylib` 和 `questions.json` 传到手机。
2. 用 **TrollFools** 打开手机淘宝 IPA → 注入 `AutoAnswer.dylib`（资源文件一并打包，或放到
   App 沙盒可读取路径，插件会优先读自身 bundle 内的 `questions.json`）。
3. 经 **TrollStore** 安装注入后的淘宝 App。TrollStore 签名永久有效，不过期。
4. 打开淘宝进入李佳琦答题页，插件自动加载（日志：`默认关闭（点悬浮球开启）`），每 0.2s
   扫描一次 UI 树。点左上角浮球「答题 / 关」→ 变「答题 / 开」即开始自动作答。

## 填题库

编辑 `questions.json`（与 `../questions.json` 电脑端为同一份，内容完全一致，方便维护）：

```json
// 单选题：q 为题面（可空），a 为答案选项文字，kw 为触发关键词
{ "q": "", "a": "1ml", "kw": ["次抛", "容量", "单支"] }

// 多选题：a 为答案数组，加 "multi": true
{ "q": "", "a": ["玻色因", "胜肽", "维 A 醇"], "multi": true, "kw": ["抗老", "成分"] }
```

匹配规则：答案文字必须出现在当前界面选项中 +（题面命中 或 任一关键词命中）才点击；
否则跳过。这样即使直播换种问法，只要考同一知识点且正确选项在屏上就能点。

## 加题库：随时可加，不用重装（热更新）

题库有两部分，**外部文件优先于内置**：

- **内置 `questions.json`**：随 dylib 一起编译进 App，改它要重新跑 GitHub Actions 构建。
- **外部 `AutoAnswer_questions.json`**（推荐日常用）：在 App 沙盒 `Documents/` 下，
  插件每次扫描（0.2s）都会检查它的修改时间，改了立即生效，无需重装、无需重编译。

**首次启动**后，插件会自动把内置题库复制成
`AutoAnswer_questions.json`（完整路径会打印在日志里，形如
`/var/mobile/Containers/Data/Application/<UUID>/Documents/AutoAnswer_questions.json`）。

**怎么加题（设备上，用 Filza 文件管理器）：**
1. 手机装 **Filza**；打开它 → 找到「手机淘宝」App → 进入它的 **Documents** 目录。
2. 找到 `AutoAnswer_questions.json`，用文本编辑器打开。
3. 照现有格式**往数组里追加一条**新题，保存即可（无需重启 App、无需重装）：

   ```json
   { "q": "", "a": "正确答案文字", "kw": ["触发关键词1", "触发关键词2"] }
   ```

4. 下次答题时插件自动读到新题。想验证是否生效，看日志里 `题库热更新生效：N 条` 的数字变大了。

> 加题只需「改这一个文件 + 保存」，不碰代码、不重编译。直播中途想加题也行，保存后下一次扫描就生效。
> 若不想用 Filza，也可以直接在电脑上编辑本仓库的 `questions.json` 后重跑 GitHub Actions 构建（走内置题库）。

## 定位真实类名（关键一步，若某版本点不动再做）

`Tweak.x` 用通用视图树扫描兜底，但若某版本选项格既不是 `UIControl` 也不能被手势命中，
请用 **FLEX**（在 TrollFools 里一并注入 FLEX 即可）在答题页点开视图树，确认：

- 题目/选项分别是什么类（UILabel / 自定义 View）；
- 点击选项是调了哪个方法 / 哪个 UIControl。

把真实 selector 填进 `tapView()` 即可 100% 命中。也可把 `tick()` 改成直接 `%hook`
该 ViewController 的刷新方法，命中即调答案 setter，比轮询更稳。

## 电脑端备选用法（WDA / XCUITest）

若不想巨魔注入，可用 `../answer_bot.py`：iPhone 跑 WebDriverAgent，电脑端连 WDA 读 UI 树、
点答案、点「确认提交」，逻辑与插件一致（同样含手动速度模拟、按题去重）。

```bash
pip install -r ../requirements.txt   # facebook-wda
python ../answer_bot.py               # 默认连 http://localhost:8100
```

## 注意

- 平台有反作弊检测，存在封号风险，仅供个人研究自动化原理，请勿用于商业化或大量刷红包。
- 淘宝版本更新可能改视图结构，插件需同步更新题库与 hook 点；浮球位置/颜色可在 `Tweak.x`
  的 `createOverlay` 调整。
