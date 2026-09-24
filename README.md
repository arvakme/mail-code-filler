# Mail Code Filler

Swift 原生 macOS 邮箱验证码菜单栏工具，支持 Gmail、QQ、iCloud、网易邮箱（163 / 126 / yeah.net）和 Outlook / Hotmail / Microsoft 365。**收到新码自动提示；卡片默认只复制，也可在设置里选择尝试填入当前输入框**。多账户同时监听；明确的 HTTPS 登录链接须手动点击打开。设置和候选统一从菜单栏面板访问。辅助功能授权可选；默认构建不需要 AutoFill profile 或通知权限，不自动提交表单。

这些邮箱可以同时监听。Outlook/OAuth 已实现，仍待真实 Microsoft 账户授权与收信验收。真实新信、未读状态、各提供商实际账户与睡眠恢复仍需实机验收；离线试用不能代替真实收信。目标和后续路线见 [PLAN.md](PLAN.md)。

## 构建与签名

需要 macOS 26+、Xcode、XcodeGen 和 Python 3；当前编译环境为 macOS 27 / Xcode 27、Apple Silicon。首次构建需要联网。IMAP/MIME 使用 SwiftMail 1.12.0（BSD-2-Clause）；标准库没有完整客户端。SwiftLog 关闭可能包含邮件内容的协议日志。SPM 和 Xcode 共用根目录的版本锁定。

```sh
test -f Config/Signing.local.xcconfig || cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
security find-identity -v -p codesigning
scripts/build.sh
```

本地配置只需填写已有签名证书和 **Team ID**。Team ID 取证书的 OU，不是名称末尾的个人标识。私钥留在 Keychain，本地签名配置不进 Git，不覆盖已有配置。本机版不嵌入 AutoFill 扩展，也不申请受控 entitlement 或 provisioning profile。脚本不注册开发者账号、不创建证书、不上传 Apple。

产物为 `build/LocalDerivedData/Build/Products/Debug/Mail Code Filler.app`。签名门验证 Apple 信任链、团队、bundle identity 与 Hardened Runtime；静态验证之外仍需实际启动。不要同时运行两个正式版本；打开新版前先退出旧版。构建目录与旧版分开，不覆盖正在运行的文件。

```sh
open "build/LocalDerivedData/Build/Products/Debug/Mail Code Filler.app"
```

`CONFIGURATION=Release` 可选择优化构建；`DERIVED_DATA_PATH` 可指定独立目录，不能指向正在运行的 App。`scripts/build.sh --compile-only` 只检查编译，未签名产物不用于交付。公开分发不在当前范围，开发签名不能替代 Developer ID、公证和 Gatekeeper 验证。

## 邮箱账户：Gmail、QQ、iCloud 与网易邮箱

在菜单栏面板的“邮箱账户”中点击“添加邮箱”，选择 Gmail、QQ、iCloud 或网易邮箱（163 / 126 / yeah.net）。可以添加多个账户；每个账户有独立的连接状态、暂停状态与钥匙串项目。

Gmail 填写邮箱与 Google 生成的 **16 位应用专用密码**，支持分组空格，不接受 Google 登录密码。先启用两步验证，再访问[应用专用密码](https://myaccount.google.com/apppasswords)。组织策略或高级保护可能禁用此方式，不应为了接入关闭保护。

QQ 邮箱连接 `imap.qq.com:993`。填写完整 QQ 邮箱地址和 QQ 邮箱设置中生成的**授权码**，不是 QQ 密码。一般在设置的账户或 POP3/IMAP/SMTP 服务区域启用 IMAP 并生成授权码；页面入口可能随版本调整。首次启动会将旧版 Gmail 凭据写到按账户隔离的新钥匙串项目并回读核验，然后才删除旧项目；如果旧项目删除失败，App 可继续启动并在下一次启动重试。Gmail 的账户身份仍等于原来存储的邮箱地址，所以网站规则和暂停设置不用改写。

iCloud 使用 iCloud 邮箱地址与 Apple App 专用密码，网易邮箱先启用 IMAP 并填写完整邮箱地址和客户端授权码；均不要填网页登录密码。网易邮箱连接时会发送服务端要求的客户端标识。不同提供商的 IDLE 能力与补查间隔可能不同，状态以面板显示为准。

### Outlook 邮箱

Outlook / Hotmail / Live / MSN 和支持 IMAP 的 Microsoft 365 使用 Microsoft OAuth 公用客户端，不使用邮箱密码或 client secret。接入前按以下步骤配置自己的 Entra 应用：

1. 在 Microsoft Entra 管理中心进入 **App registrations → New registration**，Supported account types 选择 **Accounts in any organizational directory and personal Microsoft accounts**（`AzureADandPersonalMicrosoftAccount`）。
2. 在 **Authentication → Add a platform → Mobile and desktop applications** 注册精确回调 `msauth.dev.zhijie.MailCodeFiller://auth`；在 **Advanced settings** 打开 **Allow public client flows = Yes**。macOS App 的 Info.plist 已为两个宿主目标注册 `msauth.dev.zhijie.MailCodeFiller` URL scheme，供 `ASWebAuthenticationSession` 接收回调。
3. 在 **API permissions → Add permission → APIs my organization uses → Office 365 Exchange Online → Delegated permissions** 只添加 `IMAP.AccessAsUser.All`。登录请求的 scope 为 `https://outlook.office.com/IMAP.AccessAsUser.All offline_access`；`offline_access` 是 OAuth scope，不是 Exchange API 权限。不要添加 client secret、Graph、`User.Read` 或 `Mail.Send`。
4. 复制 **Application (client) ID**，将 `Config/Signing.example.xcconfig` 复制为 Git 忽略的 `Config/Signing.local.xcconfig`（如果已有则保留原文件），把 `MAIL_CODE_OUTLOOK_CLIENT_ID = YOUR_OUTLOOK_CLIENT_ID` 改为实际 Client ID，然后运行 `scripts/build.sh` 重新构建。Client ID 是公开标识，不是密码；缺失或留空时“添加邮箱”仍显示 Outlook 项与 README 提示，但禁止授权。
5. 在 Outlook.com 的 **设置 → 邮件 → 转发和 IMAP** 启用 IMAP。Microsoft 365 租户也须允许 IMAP 与用户同意；组织策略可能要求管理员批准。然后在 App 选择 **Outlook / Hotmail / Microsoft 365**，填写完整邮箱地址，点击 **登录 Microsoft 并授权**。

该授权允许 App 通过 IMAP 访问用户有权限的邮箱，权限范围大于验证码读取。App 实际只对 INBOX 执行只读 `EXAMINE` 和有界 `BODY.PEEK`，不会标记已读、修改、删除或发送邮件。IMAP 使用 `outlook.office365.com:993` TLS；access token 仅驻内存，refresh token 按账户单独存本机登录钥匙串，轮换时先保存新 token。令牌被撤销或失效会显示“需要重新登录”，仅在用户主动点击后重新打开授权。移除账户会删除本机令牌，但云端授权需在 Microsoft 账户授权页面或组织 My Apps / 管理员处另行撤销。

真实 Outlook.com 和 Microsoft 365 授权、IDLE、静默刷新、暂停恢复及各租户 IMAP 策略尚待用户实机验证。建议发送合成验证码，检查 App 收到、原邮件未读状态不变，并重启测试静默刷新。

- 登录凭据只存本机登录钥匙串；不与 AutoFill 扩展共享，不写明文配置、日志或 iCloud。访问失败明确报错，不降级到文件。
- 只读 INBOX，不标记已读、移动、删除或发送邮件。IDLE 邮箱使用两条 TLS 连接分别监听变化和抓取，均使用 EXAMINE 与有界 BODY.PEEK，不下载附件。应用专用密码和 QQ 授权码本身的权限比本工具实际执行的读取操作更宽。
- 启动、重连、邮箱变化和 IDLE 续期时检查最新 30 封元数据，仅处理最近 10 分钟内的邮件，正文按新到旧读取。补查期间收到新推送，会在当前邮件处理完后让新邮件优先，不让它排在整批旧正文后。普通正文与 HTML 共用读取上限，各段独立识别、统一去重；补查窗口、正文限额或解码导致遗漏时显示提示。归档、垃圾箱和其他文件夹不在范围内。
- 状态区分连接、同步、监听、重连和失败，并显示最近同步完成时间。“正在同步”不代表已经确认没有验证码。菜单可暂停、恢复、更新凭据和移除账户；暂停跨重启保留，唤醒只恢复此前启用的连接。
- QQ 邮箱无登录的 TLS `CAPABILITY` 检查于 2026-09-23 收到 IDLE，因此优先使用推送。QQ、iCloud 与网易若服务器不通告 IDLE，会使用可取消的有界 NOOP 轮询；默认 QQ 约 10 秒，iCloud/网易约 60 秒，手动等码窗口内缩短到约 5 秒。Gmail 不会静默退回轮询。真实账户行为仍待用户实测。
- 不执行 Himalaya 密码命令，不依赖其进程。明确验证码在本地识别；可选 Jev 只辅助本地未识别的邮件，不决定输入目标。

### 收信连接排查

IDLE 监听每 5 分钟续期；监听期间，抓取连接每 60 秒发送一次 NOOP 并检查邮箱变化。无响应的连接会关闭并按退避策略重连，恢复后补查最近邮件。唤醒或网络路径变化也会触发重连。macOS 统一日志只记录提供方、连接状态、UID 计数和错误类别，不记录账户地址、主题、正文、验证码或链接。查看诊断记录：

```sh
log show --predicate 'subsystem == "dev.zhijie.MailCodeFiller"'
```

## 提示、填入与复制

进程启动后有新的、尚未消费的验证码和登录链接时，以同一个小型原生玻璃卡片堆叠显示，最新在上，最多显示 5 行；更多候选以“还有 N 条 · 在菜单栏查看”收起。新到候选插入顶部并轻微动画，重置自动关闭计时；卡片已显示时不重新定位。启动前补查的旧邮件仅进入菜单栏列表，勿扰期间的邮件不会在勿扰结束后补弹。重复邮件和重连不会重复入列。

卡片和菜单栏列表都按来源优先显示：头像来自发件人首字或已知服务图标，第一行显示服务/发件人名称和真实 From 的注册域名，第二行显示主题、相对时间和（多账户时）收件邮箱；右侧突出代码或“打开链接”主机与操作标签。品牌按真实 From 域名匹配，显示名称不能触发品牌识别；未知域名使用按注册域名稳定生成的颜色和字母头像。不读取邮件图片或联网拉取 favicon。

### Sender icons

目录 `Sources/Core/Resources/sender-brands.json` 维护 112 个服务的精确发件域、已知官方发信子域、颜色来源、图标来源和复核状态。品牌只按真实 From 的完整域名匹配；不把 `gmail.com`、`qq.com`、`163.com`、`outlook.com`、`icloud.com` 等个人邮箱服务域名映射成品牌头像。显示名不会触发品牌识别，未列出的子域也不会自动继承主域品牌。

目前 78 个图标来自 Apple iTunes Search/Lookup API 的官方 App Store 应用，20 个来自品牌官网图标或站点品牌标记；没有合格官网图像的 14 个服务使用首字母。数据逐项记录 App Store 的 track ID、bundle ID、seller、国家、App Store 页面和 artwork URL，或官网图像 URL、页面与原图尺寸。`scripts/fetch-sender-icons.py` 可重新抓取，依赖见 `scripts/requirements-sender-icons.txt`；运行时不联网。它将原图裁为正方形并生成 32/64/96px PNG；透明官网图标会先合成到不透明白底，以便在浅色和深色外观中辨认。App Store 与官网图标保留原色；界面按连续圆角矩形裁切并加细描边，不再使用 Simple Icons 单色重着色。头像回退时使用已记录的官方颜色；Canva 和中国移动没有可核实的单一 HEX 主色，原因保存在 `colorMissingReason`。

图标目录中的 `seasonalCheckedAt` 记录每行完成促销角标和季节性图案检查的日期；校验器会打印 `possibleSeasonalWarning` 中仍需复核的条目。官网只公布较小触控图标时，目录会记录尺寸及质量例外；改用官网横向品牌图时，会记录取标裁切中心。

每个图标数据行都记录 `iconSource`、`simpleIconsVersion`、`license` 和 `guidelinesURL`。当前官方图片的 `simpleIconsVersion` 为 `none`；`license: "none"` 表示来源没有提供逐图 SPDX 许可标记，不代表该图案属于公有领域或获准任意再发布。品牌名称、图案与商标归各自所有者；这些图标仅用于识别邮件发件方，不表示认证、合作或背书。`publicReleaseReviewed` 默认是 `false`，校验器会列出全部待复核条目；**公开发布前需逐项复核商标使用**。运行 `python3 scripts/validate-sender-brands.py` 可校验目录、邮箱域名排除规则、来源元数据和全部 PNG 尺寸；加 `--list-unreviewed` 可单独列出尚未复核的品牌。

卡片使用透明 `NSHostingView` 直接作为 panel 内容，整个堆叠共用单个 `.glassEffect(.regular, in: .rect(cornerRadius: 16))`；行内不额外加玻璃或背景，卡片外留有 24 pt 透明边距，标题栏可拖动。文字使用系统主、次级颜色，卡片跟随系统外观与玻璃辅助功能设置，不固定浅色或深色外观。窗口不加额外阴影。

“提示出现位置”默认是 **跟随鼠标**：卡片优先出现在指针右下方，避开指针；靠近屏幕边缘时会换边并限制在可见区域内。也可选 **跟随输入光标**，优先使用插入点，其次小型输入框，找不到时使用鼠标位置。拖动卡片标题栏可移动提示；“记住拖动后的位置”默认关闭。开启后按显示器记住位置，后续在该屏幕上的提示优先使用；显示器不可用或位置不再可见时退回所选位置模式。关闭开关后只影响当前卡片，已有位置保留；“重置位置”清除所有显示器记录。

“允许截图和录屏看到验证码提示”默认关闭。关闭时到码卡片及可选 AutoFill 热键填入面板不出现在系统捕获画面；开启后系统截图、录屏或屏幕共享可能记录验证码。此设置只改变捕获可见性，不改变卡片内容。卡片自动关闭时间可设 **5–300 秒**，新时长用于下一次到码提示，退出后保留。“点击验证码卡片时”默认为“只复制”；也可选“填入当前输入框（需要辅助功能）”。选择的行为退出后保留，卡片按设置显示“复制”或“填入”。

邮件有明确的登录、邮箱验证、账号激活或账号安全提醒意图，且实际目标包含一次性凭据时，HTTPS 链接才作为候选。已知邮件追踪地址会在本地解析可恢复的目标用于判断；点击时仍把邮件中的原链接交给系统默认浏览器，不会自动打开或复制。普通网站首页、登录页和服务通知页脚不算一次性链接；密码重置邮件不纳入。设置「登录链接提示范围」默认「仅登录与验证」，显示登录、邮箱验证和账号激活链接；选择「包括账号安全提醒」后，新设备登录、异常活动等安全提醒也会进入卡片和待用列表。未选范围的链接不会入列。卡片按用途显示「打开登录链接」「打开验证链接」「打开激活链接」或「查看账号安全提醒」。链接只在内存保留，最多 10 分钟，不会进入 AutoFill 验证码列表。

选择“只复制”时，点击卡片仅复制验证码。选择填入时，App 会重新核对当前前台 App、输入框、内容与选区，再尝试一次插入并回读确认；不会按 Return、提交表单或自动重试。需要辅助功能权限时，设置页会显示授权状态，并由你点击按钮打开“系统设置 → 隐私与安全性 → 辅助功能”自行授权。App 不会自动请求权限。没有授权、没有可写输入框或插入未获确认时，App 会复制验证码并在卡片上说明原因；之后可按 **⌘V** 粘贴。一次邮件包含多个候选时，每个码单独选择，不会自动挑选。登录链接始终按点击打开，不受验证码卡片设置影响。

**“收到新码时自动复制”默认关闭。** 开启后会覆盖当前剪贴板，只针对本次 App 启动之后到达的最新单候选验证码；打开开关不会追溯复制已有候选。自动复制不会消费候选。成功的手动复制、填入或打开链接只移除对应候选；卡片在仍有其他行时继续显示，最后一行被成功使用后才关闭。失败会保留候选。相同邮件的其他候选继续保留；晚到的 Jev 码即使原链接已消费仍可加入列表，但不会再次弹出已提示过的邮件。重复和过期候选不会复活。补查的历史候选仍可手动使用。

### 暂时勿扰与待用队列

菜单栏面板可选择 **30 分钟、1 小时、直到明天本地时间 08:00、直到我恢复**。开启时卡片关闭，菜单栏图标变为勿扰状态；邮件仍会接收、识别并进入待用列表，自动复制暂停。勿扰期间到达的邮件只留在列表中，结束后不会补弹卡片或补做自动复制。结束时间保存在本机设置；系统时钟、时区或睡眠恢复后会重新计算。点“恢复”可提前结束。

候选列表和到码卡片使用相同的来源优先行设计；当前网站匹配项优先，其余按新到旧排列。点击验证码行会复制；点击链接行会打开原链接。↑/↓ 移动选择，Return 执行所选行操作，⌘1…⌘9 执行当前排序的前九行。成功操作只移除被使用的候选；失败保留，其他同邮件候选仍可使用。候选未使用时最多保留 10 分钟。列表为空时显示“暂无待用验证码”。

提示卡配置为跨 Space 固定显示，并忽略窗口循环；设计上在显示桌面、切换 Space 和调度中心中保持可见。仍需在目标 Mac 上逐项确认这些系统级场景。

码保留前导零和大小写。候选最多保留到邮件接收后 10 分钟，不是网站保证的有效期。过期或已移除的候选不能继续复制；暂停或移除账户会清除列表和对应提示。不监听剪贴板；可选择 30、60 或 120 秒后尝试清除本 App 写入且未变化的验证码。剪贴板检查与清除之间有极窄竞态，历史工具和通用剪贴板仍可能留存或同步验证码。

未连接邮箱时，“离线试用”会识别一封明确标注的合成邮件，走相同提示和复制路径。连接真实邮箱后移除演示候选。需要与已有账户隔离预览时：

```sh
open -n "build/LocalDerivedData/Build/Products/Debug/Mail Code Filler.app" --args --offline-preview
```

离线预览不恢复账户、不读取钥匙串、不连接邮箱，设置与正式运行隔离；**复制仍会写入系统剪贴板**。退出预览后再正常打开以接入邮箱。

## 等码与本地反馈

日常流程只用到码卡片堆叠与点击填入/复制，不注册全局快捷键。可选 AutoFill 构建仍保留 **⌃⌥Space** 验证码选择器；选择器先捕获目标，确认后才填入。卡片与列表按当前网站与发件域的精确匹配或已列明别名优先排序。

菜单栏主面板的“我在等验证码”开启 120 秒临时窗口，可随时停止；窗口内会缩短部分邮件服务器的保活或轮询间隔。设置中的“检测验证码输入框并加快查收”默认关闭，开启后只在已授权辅助功能的普通验证码输入框上触发；可再限制为登录或验证页面。浏览器匹配默认只使用辅助功能读取前台页面域名，是否能读取 AXURL/AXDocument 取决于浏览器；可选的自动化回退仅针对 Safari/Chrome 当前标签，首次使用时 macOS 可能请求相应浏览器控制权限。其他浏览器不会申请自动化权限，所有读取仅用于本地排序，不保存完整网址。

“自动清除剪贴板验证码”默认关闭。开启后可选 30、60、120 秒；关掉开关会取消待执行的清除。设置中的“登录时启动”交给 macOS 登录项管理，系统可能要求到“系统设置 → 通用 → 登录项”批准；登录项指向当前运行的 App 副本，建议从固定位置运行后再启用。

“最近邮件里有验证码或登录链接没识别出来？”会显示进程内、最多 24 小时的未识别邮件元数据。选择一封后才使用对应账户凭据只读重取原文；暂停或移除的账户不能重取。脱敏结果需人工检查并明确保存，才会作为本机加密样本留下；原文、验证码和原始链接不写入样本。样本不自动上传。若另行启用了 Jev，仍按下节说明发送符合条件的疑难邮件。

## 可选：Jev 辅助识别

打开齿轮“识别与提示”，可粘贴 TypeSafe API Key 后点“保存并启用”，或点“从 .env 文件导入…”选择一个环境文件。App 只解析其中的 `TYPESAFE_API_KEY`，不执行 shell、密码命令或其他配置。密钥保存到本机登录钥匙串，不进 App 包、UserDefaults、日志或 Git。Jev 默认关闭；关闭开关取消在途识别，移除密钥会删除本 App 保存的副本，不修改原环境文件。

明确验证码立即走本地识别，多个明确候选保留手选。只有本地没有结果、且存在数字或混合字符候选的邮件，才使用 Jev。**启用会把发件人、主题和最多 1500 字规范化正文发送到 TypeSafe**；包含待判断的真实验证码，不发送邮箱密码、授权码或附件。截取不会把半个数字串作为候选，引用正文不进入模型上下文。

模型使用 `jev-latest` 的类型化判断，只能从最多 8 个原文候选中选择，不能生成新码或改变大小写、前导零。置信度不足不采纳。请求最多 4 秒、不自动重试、不跟随重定向；失败在菜单栏面板显示，不伪装成“没有验证码”。模型请求与收信分开，后来的本地明确码不等它；暂停、换账户、退出或禁用后，迟到结果不能恢复候选。开启开关不重放历史邮件。

设置底部显示最近一次“本轮同步至正文”和“本地/Jev 识别”耗时，不含服务器投递或推送前的等待，不能据此宣称端到端已快于 Telegram。`--offline-preview` 不恢复任何密钥、不调用 Jev；真实 API 的合成邮件验证须显式执行：

```sh
MAIL_CODE_JEV_LIVE_TEST=1 swift test --jobs 4 --filter JevCodeResolverTests.liveSyntheticMailOnly
```

该检查使用上述环境文件中的密钥，只发送内置合成邮件，不读取真实邮箱。它证明当前客户端能调用 API，不代表各种真实邮件都能正确识别。

## 可选：官方系统 AutoFill

源码保留独立 AutoFill 构建入口，但不是默认本机版本，**尚未完成签名、系统启用与真实填码验收**。苹果不向免费账号提供 AutoFill Credential Provider capability，即使只自己用也需要适用的 profile。普通开发签名能够运行本机复制版，不表示可以运行受控扩展。

```sh
scripts/build.sh --autofill
# 仅检查宿主和扩展编译，不生成可运行交付：
scripts/build.sh --autofill --compile-only
```

需要两个显式 App ID：`dev.zhijie.MailCodeFiller` 与 `dev.zhijie.MailCodeFiller.AutoFill`，启用 AutoFill Credential Provider 与 Keychain Sharing，并安装授权现有开发证书及本机 UDID 的 development profile。在本地配置填写 `MAIL_CODE_HOST_PROFILE` 和 `MAIL_CODE_EXTENSION_PROFILE`。不需要 App Group；共享组前缀来自 profile 的 AppIdentifierPrefix。

签名门核对证书、设备、平台、期限、团队、bundle identity、实际 entitlement 与共享组。扩展只包含验证码共享组，不能访问宿主 IMAP 登录凭据组。产物位于 `build/AutoFillDerivedData`，与本机复制版共用应用身份，不能同时运行。

签名后需在系统设置手动启用，再验证 Safari/Chrome 的 OTP 列表及输入。要成为网站建议，需在 App 中明确关联接收账户、完整发件人与网站域名；不从品牌或邮件链接猜域名。关联不证明发件人真实，系统决定何时展示，不能保证任意输入框都会弹出。

宿主通过本机 Data Protection Keychain 写入短期候选，不含主题、正文或邮箱凭据；设备解锁时读取，不同步 iCloud。扩展每次取码核对身份、关联与期限，不自动提交。暂停、移除和正常退出清空共享候选；清理失败会提示，默认保留 App，只有明确选择“仍然退出”才结束。异常退出后仍按期限拒绝旧码。系统索引不存明文验证码。

⌃⌥Space 选择器与 ⌃⌥V 快速填入也在该构建中提供：用户自行授权辅助功能，写前核对原控件、值、选区，单次写入并回读；目标变化或结果不确定时拒绝，不自动重试。它们不代表系统 AutoFill 已通过。

## 验证

```sh
swift test --jobs 4 --filter 'CandidateDeliveryTests|DeliverySettingsTests|GmailSessionTests|JevCodeResolverTests|MailCodeGmailTests'
python3 scripts/test-signature.py build/Debug-local-settings.json
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
```

剪贴板测试用独立命名的 pasteboard，不修改系统剪贴板。协议测试只连本机合成服务器。完整相关入口还包括 `MailCodeGmailTests`、`MailCodeCoreTests`、`AutoFillTests` 和 `scripts/test-autofill-signing.py`；按改动范围选择，不把离线测试当成真实邮箱验收。

实机验收需在自己的网站请求新码，核对提示、点击复制、粘贴结果和原邮件未读状态；再分别测试自动复制开关、重复新信、暂停、断网和睡眠恢复。macOS 26、锁屏、多屏、暗色和 VoiceOver 都需独立证据，macOS 27 编译不能代替。未经对照不宣称已经优于 Apple 自带功能。
