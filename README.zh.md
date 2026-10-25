# auto-compat-zig

当前版本 **0.2.0**（`auto-compat --version` / `version` / `-V` 直接打印；`help`/菜单首行也带；0.x 规则：日常修复只递增末位，开源发布（0.2.0）动了 minor）。

> 只想知道怎么用？见 **[使用文档.md](使用文档.md)**（快速开始 / 调用示例 / 探针 / 常见问题）。
>
> 0.1.6/0.1.7 起：**CLI 严格解析（只有一种显而易见写法；显式优于隐式）**——每个选项只有
> `--opt VALUE` 一种写法（`--opt=VALUE` 拒绝并给出正确写法）；同一选项不得重复（`--url` 是可
> 多次给出的数据项，除外）；矛盾组合（`--key` 与 `--key-env` 并存、`--no-verify` 与
> `--verify-models`/`--verify-paid` 并存、`--verify-models 0`）直接拒绝；未知选项/缺失值/空值/
> 类型错误/杂散参数 exit 2 并附用法（拼错给 `did you mean` 建议）；`-h/--help`、`-V/--version`
> 只能单独出现；`serve` 拒绝额外参数（网关配置只走环境变量；`gateway` 别名已移除）；菜单只认
> 屏幕上的键（1/2/3/q，回车取显示中的 `[1]`）；无效的数值环境变量启动时点名并给出实际默认值。
>
> 0.1.4 起：上游空闲超时默认 **600s**（`AUTO_COMPAT_IDLE_TIMEOUT_MS`，0=关），网关启动日志与 `GET /` 的
> `limits` 块显式说明；项目/二进制/环境变量已从 dsh 命名改为 **auto-compat** / `AUTO_COMPAT_*`（见下）。

### ⚠ 0.1.4 破坏性变更：项目/二进制/环境变量改名

Zig 版不再暗示 dsh（它零依赖、面向所有 AI agent）：项目 `dsh-compat-zig` → **`auto-compat-zig`**，
二进制 `dsh-compat` → **`auto-compat`**；环境变量两版统一换到 `AUTO_COMPAT_*` 命名空间
（不提供旧名回退）。**厂商密钥名与 providers.json schema 不变**。

| 旧名 | 新名 |
|---|---|
| `DSH_COMPAT_PROVIDERS_FILE` | `AUTO_COMPAT_PROVIDERS_FILE` |
| `DSH_COMPAT_MENU` | `AUTO_COMPAT_MENU` |
| `DSH_COMPAT_DEBUG` | `AUTO_COMPAT_DEBUG` |
| `DSH_COMPAT_RETRY_DELAY_MS` | `AUTO_COMPAT_RETRY_DELAY_MS` |
| `DSH_COMPAT_PLACEHOLDER_MS` | `AUTO_COMPAT_PLACEHOLDER_MS` |
| `DSH_COMPAT_IDLE_TIMEOUT_MS` | `AUTO_COMPAT_IDLE_TIMEOUT_MS` |
| `DSH_GATEWAY_HOST` / `DSH_GATEWAY_PORT` | `AUTO_COMPAT_GATEWAY_HOST` / `AUTO_COMPAT_GATEWAY_PORT` |
| `DSH_LLM_COMPAT_GATEWAY_TOKEN` | `AUTO_COMPAT_GATEWAY_TOKEN` |

（迁移：把脚本/服务里的旧变量名逐一替换为新名即可；`INTERN_AI_API_KEY` / `AMD_RADEON_API_KEY`
等厂商密钥名不动。）



用 **Zig 0.17（纯 std，零第三方依赖）** 复刻的 LLM API 兼容屏蔽层网关——TS 版
`dsh-llm-compat` 的 127.0.0.1 中转核心功能。**单二进制**（网关 + 闭环探针）：监听
本地端口，把 OpenAI Chat / OpenAI Responses / Anthropic Messages 三种入站方言翻译
到三种上游方言，厂商怪癖（思考档位、参数白名单、错误信封、无状态化）全部屏蔽在内部。

网关自带**运行时自愈**：上游原生支持入站方言就保持原生，否则由已验证的方言映射后供给
下游；**成功一次即固定**路径与方言并原子写回 providers.json；偶发失败（5xx/429/档位被拒）
网关内部退避重试，消化不了才把错误抛给上层。

## 构建与运行

```sh
zig build                 # 产出单二进制 zig-out/bin/auto-compat（网关 + 探针）
zig build test            # 单测（档位归一、/vN 剥离、SSE 解析、图片注册表、参数分发、自愈缓存）
python3 tests/e2e_selfheal.py   # 运行时自愈 e2e（本地假上游，确定性、零真机依赖，9 场景）
                                # 单测另覆盖六个方言适配器（解析/组装/SSE 帧序/序列化）与自愈决策表

# 运行（密钥只走环境变量）
export INTERN_AI_API_KEY=sk-...
export AMD_RADEON_API_KEY=rc-...
./zig-out/bin/auto-compat                  # 终端里直接跑 → 交互菜单

# 子命令（脚本/服务用，无菜单）：
./zig-out/bin/auto-compat serve            # 网关（监听 127.0.0.1:8686）
./zig-out/bin/auto-compat probe --key-env MY_KEY [--url 裸站点] [--out providers.json]
./zig-out/bin/auto-compat help             # 用法 + 环境变量

# 可选 providers.json（自定义上游，schema 同 TS 版）
AUTO_COMPAT_PROVIDERS_FILE=./providers.json ./zig-out/bin/auto-compat serve
```

### 菜单与模式

无参数 + TTY 时出菜单（回车=网关；**2=探针向导：优先直接粘贴 API key**，回车改读环境变量名，
空 key 就地重问，任意一步 q 取消；3=帮助；q=退出）。无参数 + 非 TTY（服务、重定向、管道）
直接跑网关，行为与旧版一致；`AUTO_COMPAT_MENU=1|0` 可强制开/关菜单。

providers.json 条目：

```json
[
  { "name": "ds-resp", "baseURL": "https://discovery-api.intern-ai.org.cn/v1",
    "protocol": "responses", "apiKeyEnv": "INTERN_AI_API_KEY",
    "verifiedModels": ["glm-5.3"] }
]
```

`protocol`：`openai`（缺省）| `anthropic` | `responses`。`baseURL` 允许裸站点：
装载时自动发现路径后缀并拉取模型目录（限流退避、WAF JSON 判别）。探针已内置
同一二进制（见下），无需再借 TS 版工具。

装载期做**同端点去重**（内置优先）：某条目解析出的端点与已有供应商完全相同时（如探针
`--url` 指向了内置厂商，产出与内置同端点的 `custom-N`），该条目不再注册成第二个供应商
——否则裸模型 id 必然歧义。日志（全程序输出保持 ASCII，Windows 代码页下不乱码）会说明
条目被忽略及其固化信号不生效：

```
[auto-compat-zig] providers.json: entry "custom-1" resolves to the same endpoint as built-in "intern-ai" (…) -- same endpoint = same provider; keeping "intern-ai", ignoring the entry (…). Use a different baseURL for an independent provider.
```

裸模型 id 命中多家供应商时，400 错误会列出候选并给出写法（可直接照做）：

```
model "glm-5.3" exists in: intern-ai, custom-1; use "provider/model", e.g. "intern-ai/glm-5.3" or "custom-1/glm-5.3"
```

## 路由（无后缀映射）

任意 `/v1`、`/v2`、任意 `/vN` 前缀剥除后按同一张路由表匹配：

| 路由 | 方言 | 说明 |
|---|---|---|
| `POST /chat/completions` | OpenAI Chat | 流式 + 非流式 |
| `POST /responses` | OpenAI Responses | 流式 + 非流式；`store`/`previous_response_id` 无状态化 |
| `POST /messages` | Anthropic Messages | 流式 + 非流式 |
| `POST /messages/count_tokens` | Anthropic | 本地 ~4 字符/token 估算 |
| `GET /models` | OpenAI | 聚合模型目录（`provider/model` + 无歧义裸 id） |
| `GET /providers` | JSON | 供应商视图 |
| `GET /` | JSON/HTML | 自描述清单 |

## 屏蔽层行为（与 TS 版一致）

- **档位归一**：`none/disabled/false→off`、`ultra→max`、未知→`medium`；按厂商剖面
  收敛（intern-ai `off→none`；AMD GLM `off/minimal→low`、`xhigh/max→high`；AMD MiMo
  `off→none`）；未知厂商永不透传（防 400）。
- **消息投影**：空 user 消息跳过；`developer`→`system`；历史 reasoning 丢弃；
  图片非视觉模型替换占位文本；空工具结果 `(no output)`；Anthropic 上游 tool_result
  合并进 user 消息。
- **无状态**：Responses 上游固定 `store:false`、永不发 `previous_response_id`。
- **错误映射**：OpenAI `error` / FastAPI `detail` 双信封 → `AUTH`/`RATE_LIMIT`/
  `CONTEXT_WINDOW_EXCEEDED`/`SERVER`/`INVALID_REQUEST`；Retry-After 保留。
- **SSE 容忍**：任意 event 名、`[DONE]`、`event: done`（AMD）全接受。

## 运行时自愈（网关）

- **方言路由**：按 (provider × 入站方言) 学习——原生可用则原生直发；不可用（404/405/非 JSON）
  则翻译到该 provider 已验证的 primary 方言（providers.json `protocol` / 内置声明 / 运行时探测）。
- **成功即固定 + 写回**：任何一次 2xx 固定 `{baseURL, protocol}`，首次/变化时原子写回
  `AUTO_COMPAT_PROVIDERS_FILE`（默认 ./providers.json；同名覆盖、保留其它字段、重启直接复用）。
- **失败兜底**：路径/方言不匹配时按 URL 形状"增/减后缀"紧凑发现（近邻 5 候选 + 120ms 节流）
  并闭环 ping 方言；命中即固定重试；无进展负缓存 5 分钟。启动后后台预热未解析条目。
- **偶发内部消化**：5xx/网络退避 2s/5s 重试；429 按 Retry-After（≤10s）等待；档位被拒自动
  "省略 → medium"重试并记住该 (provider, model)，后续第一次尝试就应用；总预算 ~20s。
  仅 AUTH/上下文超限等真错误直接上抛。自愈过程打 stderr 日志（`mapping via …`/`route fixed: …`）。
- 可用 `AUTO_COMPAT_RETRY_DELAY_MS` 按百分比缩放退避（默认 100；测试可设 1）。

## 占位保活（placeholder keepalive，0.1.2 起默认开启）

流式请求等待上游超过 **55s**（`AUTO_COMPAT_PLACEHOLDER_MS` 可调，`0` 关闭）时，网关向客户端注入一个
"伪装成模型开始输出"的占位（`U+2063`+`…`+`U+2063`，界面里只见 `…`），防止客户端 idle 超时提前
断开连接。CLI 启动网关时会在日志里注明状态：

```
[auto-compat-zig] placeholder keepalive: ON (threshold 55000ms, streaming only; ... AUTO_COMPAT_PLACEHOLDER_MS=0 disables)
```

- **发给上游前自动剥离**（省 token）：客户端把占位回灌进历史时，网关按**精确串**删除；
  没有启发式——正文里正常的 `…`、用户打的 `…` 一律不动；
- **不动历史结构**：不删消息、不删块、不重排（消息数/顺序逐字节稳定）——改动历史结构会让上游的
  前缀缓存整段失效，代价远大于省下的 token；
- **缓存友好**：剥离幂等且确定（`strip(strip(x))==strip(x)`），每轮发上游的历史单调稳定；

> **0.1.17 修复（保活此前实际无效）**：流式帧此前只调用了 `BodyWriter.writer.flush()`（把帧排进
> 连接写缓冲），没有调用 `BodyWriter.flush()`（把连接写缓冲推到 socket）；响应头 likewise 要等
> 第一次 write/end。结果：等待上游期间客户端连 200 都看不到，占位帧也全部滞留到响应结束才一起到达
> （日志却已打了 `placeholder keepalive: injected`，极具误导性）。现在：响应头在开始等待上游前立即
> flush；每个真实帧/占位帧写完后两级 flush。e2e 用墙钟断言锁死"占位必须在静默期到达（<1.5s）"。
- **残余（已记档）**：若客户端清洗掉不可见字符，占位会退化成字面 `…` 而认不出，此时按规则"不动"
  ——约 1 token/次、字节稳定、不影响缓存；
- 仅流式生效（非流式无法中途写 JSON）；工具/思考块流中途不注入（避免把工具参数拆块）。

## 上游空闲超时（0.1.3 起默认开启）

上游超过 **600s**（`AUTO_COMPAT_IDLE_TIMEOUT_MS` 可调，`0` 关闭）没有任何数据 → 看门狗**打断**该连接
（`shutdown` 阻塞读），失败归类为 `TIMEOUT` 并交给既有自愈逻辑（只发过占位/未发帧则退避重试，
尝试耗尽才上抛，错误信封带 `code=TIMEOUT`）。启动日志注明：

```
[auto-compat-zig] upstream idle timeout: ON (600000ms per attempt, retried by self-heal; AUTO_COMPAT_IDLE_TIMEOUT_MS=0 disables)
```

没有它时，黑洞/半开的上游会把请求**永久挂住**（占位保活让客户端不再主动超时，问题只会更隐蔽）。
流式与非流式请求都受保护；重试会重新计时（每次尝试独立 600s）。

## 入站 key 直通（key 中转，0.1.5 起）

很多客户端（如 dsh 的供应商 UI）会在请求里带上 API key，而不是让网关读环境变量。网关现在：

- **环境变量优先**：`apiKeyEnv` 有值（非空）→ 用它（既有部署零变化）；
- **环境变量缺失 → 直通入站携带的 key**：`x-api-key`（Anthropic 客户端风格）优先，其次
  `Authorization: Bearer X`（也接受裸 Authorization）；上游按自己的方言重新组头（Bearer / x-api-key）。
  日志留痕：`<provider>: forwarding the inbound client API key upstream (<ENV> unset)`；
- **网关令牌绝不外传**：配了 `AUTO_COMPAT_GATEWAY_TOKEN` 时，与之相等的入站 Bearer 只用于给网关鉴权，
  不会被当上游凭据（那是把网关密码递给上游）；
- **两者都没有 → 快速失败**：`code=MISSING_CREDENTIAL`（HTTP 401 类，**不重试**——配置问题），
  报错文案给出两条补救路径：`export <ENV>` 或随请求带 key。

运行时路径发现（route discovery）同样使用这份"环境变量优先、其次入站"的 key，否则直通场景下发现会 401。

## 内置厂商剖面

## 内置厂商剖面

| 路由 | 端点 | 模型 | 要点 |
|---|---|---|---|
| `intern-ai` | discovery-api.intern-ai.org.cn/v1 | glm-5.3, deepseek-v4-flash-vision | off→none、honorsStop |
| `amd-radeon` | developer.amd.com.cn/radeon/api/v1 | MiMo-V2.6-Flash, GLM-5.3-Flash | 档位钳制、honorsStop=false、别名表 |

## 探针（同一二进制的 `probe` 模式 / 菜单选项 2）

移植了 TS 版的闭环探针 + 路径自动发现（`resolveApiBase`，15 种候选后缀 ×
祖先层级剥离 + 闭环验证）：

```sh
# 只给 key：按内置厂商 + 5 家免费预设找家（命中即停，不再轮询其余候选）
./zig-out/bin/auto-compat probe --key-env MY_KEY

# 裸站点 URL：路径后缀自动发现（/v1、/api/v1、/paas/v4…）
./zig-out/bin/auto-compat probe --key-env MY_KEY --url https://developer.amd.com.cn/radeon

# 输出固化到 providers.json（网关装载即用）；用户 URL 全部试探、命中端点与
# 内置厂商/预设相同时按内置名固化（不写重复 custom-N）、同端点只固化一条
./zig-out/bin/auto-compat probe --key-env MY_KEY --out providers.json --verify-models 8

# --url 可多次给出（每个值是不同的数据项）；其余选项一律只写一次。
./zig-out/bin/auto-compat probe --key-env MY_KEY --url https://a.example --url https://b.example
```

`probe` 的参数是**严格**的（0.1.6/0.1.7 起，用户裁决"只有一种显而易见写法；显式优于隐式"）：

- 每个选项只有 `--opt VALUE` 一种写法：`--key=sk-x`、`--out=x.json` 等 `=` 写法 exit 2 并
  提示正确写法；同一选项重复给出（`--out a --out b`）同样拒绝（`--url` 除外）。
- 矛盾/冗余组合直接拒绝：`--key` 与 `--key-env` 并存、`--no-verify` 与 `--verify-models`/
  `--verify-paid` 并存、`--verify-models 0`（跳过验证的正规写法是 `--no-verify`）。
- 未知选项/缺失值/空值/`--verify-models` 非数字/杂散位置参数 → exit 2 + 用法；拼错给近似建议
  （`--no-verfiy` → `did you mean --no-verify?`）；`--out` 后跟另一个选项按"缺值"报错
  （值不允许以 `-` 开头）。全部解析错误都不触网、不写文件。
- `probe -h/--help`、`-V/--version` 只能单独出现：带其它参数会被拒绝并提示
  `run: auto-compat probe --help`。

向导（菜单 2）同样只接受屏幕上展示的写法：非数字、`0`、非 y/n 一律就地重问并给出正确指令；
回显的等价命令行与实际选项一致（含 `--verify-paid`），可直接复制复现。

装载器同样输入宽容：providers.json 的 baseURL 允许裸站点，启动时自动发现
路径后缀并拉取模型目录（限流退避、WAF JSON 判别、闭环验证）。

## 与 TS 版的差异

- 不含 dsh 插件集成（探针 CLI 与路径自动发现已内置）。
- 网关图片走 data URI 直传上游（无持久附件服务对接）；`src/images.zig` 附件注册表**保留但当前不参与运行时**
  ——唯一保留理由：将来对接宿主附件服务/图片换存时可直接启用（见文件头注释）。
- 线程模型：每连接一线程 + 每请求 arena；TLS 由 std.crypto 白送。

## 校验记录（2026-10-06 真机）

四方言矩阵全绿：openai-chat（intern-ai + amd，档位收敛）、anthropic（thinking/text
块、canonical 事件序 message_start→…→message_stop）、responses（reasoning/message
输出、response.created→…→response.completed 事件序）、/vN 前缀、/models、/providers。

2026-10-08 真机复验（单二进制 + 双供应商 key）：探针 intern-ai 全部 10 模型闭环验证
（含 glm-5.3、deepseek-v4-flash-vision）、amd 9 模型目录识别；网关 chat 流式/非流式、
/messages、/responses、/v2 前缀、providers.json 装载（自定义条目 + 裸站点路径发现）
全绿。同日修复：多条目固化产出 `},,{` 非法 JSON（Stringify 自动逗号 + 手工逗号重复）、
AMD `/models` gzip 目录未解压导致路径发现 miss（`requestOnce` 改用 `client.fetch`）。

2026-10-08 运行时自愈（第二轮）：假上游 7 场景 e2e 全绿（裸站点运行时后缀发现、原生 404 →
方言映射、档位被拒 → 省略重试并记住、503 退避、429 Retry-After、401 直抛、成功路径写回
+ 重启直连）；真机 6/6（intern-ai 与 amd-radeon 三方言入站全部 200，成功路径写回
providers.json）。同轮修复：流式 `send_buffer` 全局共享导致并发互踩、上游错误路径读
`response.head` 的野指针崩溃（`reader()` 会 `invalidateStrings()`）。

2026-10-08 清理与补测（第三轮）：冗余清单按决定执行（images 保留并写明唯一理由；删除
`clock.newId`、`auxiliaryEffort`、`Detection`、`UpstreamOptions`、`Preset.effort_param/free`、
`types.Model`、`unknown_context_window`、`Chunk.block_start`、`SseFrame.event`、gateway 6 个
死 import、`src/tests/` 空目录等 11 类）；`stopped_early`（429 熔断）接进探针输出；
Responses `function_call` 修好（done 带全字段、并行多工具各占一个 output_index、零参数不丢）；
六个方言适配器首次补齐单测 + 自愈决策 `decideFailure` 逐分支测试；e2e 增至 8 场景全绿。
同日菜单向导改版：**优先直接粘贴 API key**（回车才读环境变量），空 key/未设置的环境变量名
就地重问（不再把空任务丢给执行层），向导内任意一步 `q` 取消返回菜单；程序自身不在任何输出中
打印明文 key（提示语明示粘贴会由终端回显）。

2026-10-14 占位保活 + 测试基建修复：新增"上游静默 → 客户端占位注入（发上游前精确剥离）"，
两版对齐（Zig 看门狗线程 / TS 定时器）；阈值默认 55s、CLI 启动注明、可关。同轮发现并修复：
① **测试聚合器漏跑 5/6 个方言测试套件**（`pub const` re-export 不会收集 test，需显式 `@import`）——
接通后立刻暴露 ② **OpenAI 入站工具帧 JSON 少一个闭合括号**（生产 bug，客户端解析必失败）与
6 处过期的测试期望；③ 看门狗注册表按值存拷贝导致注销失配（悬垂指针风险）。单测 78/78、
e2e 11 场景（新增 placeholder 场景）全绿。

2026-10-10 歧义治理：① 装载期**同端点去重**（内置/先注册者优先；条目被忽略的原因与后果写进
启动日志）；② 裸模型名歧义 400 改为可行动：列出候选并给出 `provider/model` 写法；③ 歧义判定
与 TS 版对齐（同一剖面内重复 id 不再算歧义）。单测 33/33、e2e 增至 9 场景（新增 dedup 与
ambiguity 两个场景）全绿；三平台 ReleaseSafe 重编。

2026-10-16 CLI 排列组合勘察与严格化（0.1.6）：按"用户会随机排列组合选项"实测 60 例输入（顺序洗牌、
值缺失/空、`=` 写法、重复选项、`serve` 带参、菜单空白/垃圾项、无效环境变量），逐项归类并修掉
**一定有问题**的行为：① 未知选项/杂散参数被静默忽略（`--no-verfiy` 拼错会白跑、`--key=sk` 被丢成
"no key"）；② `--out` 会把下一个选项吞成文件名、缺值/空值静默落回 providers.json（空值甚至跑完
整个探针才报 `FileNotFound`）；③ `--verify-models abc/-1` 静默当默认 8；④ `serve --port 9000`
静默忽略仍是 8686、`serve --help` 直接起网关挂住；⑤ `probe --help/--version` 在非首位被忽略
（带 key 时会真跑探针并写文件）；⑥ 无效的 AUTO_COMPAT_GATEWAY_PORT/PLACEHOLDER_MS/IDLE_TIMEOUT_MS/
RETRY_DELAY_MS/MENU 静默回退、PORT=0 日志谎报 `:0`、无效 HOST 只给裸 `error: Overflow`；
⑦ 向导对非数字静默当 8、回显的等价命令行丢掉 `--verify-paid`。修法：严格解析器
（`--opt=VALUE` 与空格写法等价、help/version 任意位置生效、拼错给 `did you mean` 建议——`=` 等价与
"任意位置生效"两条在 2026-10-19 按用户裁决撤回，见下条；
错误即 exit 2 并附用法）、serve/gateway 参数裁决、无效环境变量启动点名、向导重问；
TS 探针 CLI 同规则同步。单测 98/98（新增 cli_match/env.parseInt/严格解析/等价命令向量）、
e2e 增至 14 场景（新增 cli-strict，105 项断言）全绿。

2026-10-19 用户裁决执行（0.1.7）：**"只有一种显而易见写法；显式优于隐式"**——上一轮勘察留下的
8 项"设计意图存疑"按下述执行：同一声明不得有第二种写法/重复/矛盾组合，遇到即**警告并拒绝、
同时给出正确指令**（不触网、不写文件）。具体：① `--opt=VALUE` 一律拒绝（上一轮加入的等价支持
撤回），提示 `write --opt VALUE`；② 重复选项拒绝（`--out a --out b`、`--key a --key b`、
`--verify-paid --verify-paid`…；`--url` 是可多次给出的数据项，除外）；③ `--key` 与 `--key-env`
并存拒绝（不再让 inline 静默胜出）；④ `--no-verify` 与 `--verify-models`/`--verify-paid` 并存
拒绝（"keep one"）；⑤ `--verify-models 0` 拒绝（跳过验证只有 `--no-verify` 一种写法）；
⑥ `probe --help`/`--version` 只能单独出现（带参数 = 冗余写法，拒绝并提示
`run: auto-compat probe --help`；上一轮"任意位置生效"撤回）；⑦ `gateway` 别名移除
（`unknown command: gateway` + `use "serve"`），顶层 `help probe`/`version --json` 同样拒绝并
指向正确指令；⑧ 菜单只认屏幕上的键 `1/2/3/q`（文字别名移除，回车取显示中的 `[1]`）；
向导对非数字/`0`/非 y/n 就地重问。保留的"显式默认"：屏幕上标注的默认值（`[1]`/`[providers.json]`/
`[8]`/`[y/N]`）回车生效——默认值本身是显示出来的，不属于隐藏行为；无效的数值环境变量仍是
"点名 + 实际默认值"（有明确、被记录的行为；不因一个可选旋钮的笔误拒绝启动网关）。单测
101/101（新增冗余写法/重复/矛盾/别名/菜单/向导重问向量）、e2e 场景 14 扩到 44 项断言全绿；
TS 探针 CLI 同规则同步 → 0.1.6（97 单测）。

2026-10-19 Responses 失败信号规范化（0.1.8，真机反馈）：客户端用 Responses 模式调网关，上游
502/429 重试耗尽后只看到"模型未返回任何内容"（`empty_model_response`）。字节级复现（假上游稳定
502 + 流式/非流式两条入口）定位：**失败信号不是规范形状**——流式的 `response.failed` 只有
`response.error`（缺 `id`/`object`/`status`/`model`/`output`，严格客户端当未知事件忽略，流走完
即"空响应"）；非流式把**流事件形状**当 HTTP 错误体发（客户端在顶层读不到 `error.message`）。
修法：① 流式失败发完整 Response 对象（`status:"failed"` + 完整 `error{code,message,type}` +
`model`/`output`/`usage`），且 `created`/`completed`/`failed` **共用同一个 `resp_…` id**（身份不再
中途换人）；② 非流式失败走标准错误信封 `{"error":{message,type:"gateway_error",code}}`；
③ 顺带：装载期对每个条目探测前先打点（`providers: entry "x": resolving …`）——此前不可达端点的
装载探测会静默扫 34 个候选后缀（每次 300ms 节流）≈9s 无任何输出，像卡死。单测 102/102
（新增失败帧规范形状 + 同 id 向量）、e2e 增至 **15 场景**（新增 responses-fail：两种上游方言路径
× 流式/非流式，直跑与 zip 内二进制各一遍）。TS 版同形状同步 → 0.1.7（99 单测）。

2026-10-20 原生方言反复失败 → 换方言（翻译）兜底（0.1.9）：用户要求——"下游强求 responses 格式，就按上游
实际存在的格式映射给他"。此前"原生优先 + 映射兜底"只在 404 类信号（PATH_MISMATCH）触发：上游
/responses 持续 502/429/TIMEOUT 时只会原地重试，耗尽即上抛（真机案例：厂商 /responses 坏而
/chat/completions 正常，客户端却拿到失败）。现在：5xx/429/TIMEOUT 重试耗尽后，若仍在原生方言上且有
映射目标（primary），把最后一次机会用于切 primary 做翻译重试，并记"原生不可用"——同进程内后续请求
直走映射，不再白等重试；换方言后重试计数清零（映射方言有自己的额度）；只换一次、不横跳；已在映射
方言上则直接上抛；AUTH/上下文超限等真错误不换方言。日志讲清触发原因：
`native responses failing after retries (last HTTP 502), mapping via openai`。单测 103/103
（decideFailure 换方言兜底五向量）、e2e 增至 **16 场景**（新增 dialect-fallback：/responses 坏 +
chat 正常 → 非流式/流式都拿到 Responses 格式完整回答；第二条请求直走映射；日志留痕）。
TS 侧无需镜像：其 intern-ai 适配器原生走 chat/completions（responses 入站本来就翻译）；
responses-原生厂商的同类兜底记入 backlog。

2026-10-20 三方言互备环 + 失败报告口径（0.1.10）：用户要求——"不止 response 向其他两个翻译；三个中任何
一个出问题，都要自己向另外两个翻译尝试"。把上一轮的"换一次（原生→primary）"升级为**方言环**：
① 任何一条方言反复失败（5xx/TIMEOUT/429 重试耗尽，或 404 类路由缺失）都沿环试下一条——顺序为
primary 优先、其余按翻译距离（openai↔responses 同族优先，anthropic 最远），最多换两次（三条都试到）；
② 坏记忆按方言记账并带 **TTL（300s）**：某条方言坏了先避开，过期自动再试一次（避免一次抖动永久改道），
成功一次即清零；发现（discovery/prewarm）探通某方言也会清它的坏记忆；
③ 第一次换方言不受预算限制（客户端的真实诉求可能是"这条路由挂了"），第二次换要求还在总预算内；
④ 失败报告口径：放弃时报告"有信息量"的那个失败——回退探测的 404（PATH_MISMATCH，只是那条路由不存在）
不再顶掉真实问题（TIMEOUT/RATE_LIMIT/SERVER）；发现失败同样口径。
单测 105/105（环候选顺序、坏记忆与 TTL、两次换方言的预算闸门、失败口径）、e2e 增至 **17 场景**
（新增 dialect-ring：responses+chat 都坏 → 第三条 anthropic 顶上且 responses 入站拿到完整回答；
chat 坏 → 换 responses 翻译；日志留痕 2/3、3/3）。TS 侧无对应机制（单次尝试、无方言环），记入 backlog。

2026-10-20 系统提示归一（0.1.11，真机追查副产品）：排查"responses 请求上游 502"时抓包发现
**chat 入站与 responses 入站的系统提示被整个丢掉**——三个上游序列化器都只读 `request.system`
并且都跳过 messages 里的 system 角色（注释写着"已在入口归一"），但那个归一步骤从未实现：只有
anthropic 入站自己填了 `request.system`。于是 chat 入站带 `{"role":"system"}`、responses 入站带
`instructions` 时，**模型根本收不到客户端的 agent 指令**（工具协议/输出格式/人格全丢），表现为
"模型像没收到指令"或空/无用回答。修法：`types.extractSystem`（纯函数：system 块 → request.system，
多段按序空行拼接，已有值不覆盖）在 `callHealed` 入口统一应用——覆盖三个入站 × 三个上游 × 映射路径。
单测 106/106（新增归一五向量）、e2e 增至 **18 场景**（新增 system-prompt：三种入站的系统提示都必须
到达上游，含回归确认）。另确认：档位字段（reasoning.effort）只在"未知厂商"上按策略省略，
内置 intern-ai 剖面正常透传（preset 抓包实证）。

2026-10-20 Responses 事件规范字段（0.1.12，真机"空回答"根因）：zcode 的 Responses 客户端对**每个 SSE
事件做 schema 校验**，不合格的事件整条丢弃。我们的帧缺少它（以及 OpenAI 规范）要求的字段：
`response.created` 缺 `created_at`、`output_item.*` 的 `item` 缺 `id`、各类增量事件缺 `item_id`
（推理增量还缺 `summary_index`）、`function_call` 的 done 缺 `status`——于是事件全被丢弃，客户端只显示
"已工作 N 秒"、没有任何内容（与上游是否 502 无关）。修法：`StreamOut` 为每个 output item 生成稳定 id
（`msg_N`/`rs_N`；工具 item 用 call_id），所有增量带 `item_id`（文本另带 `content_index`、推理带
`summary_index`），created/completed/failed 带 `created_at`，工具 done 带 `status:"completed"`；
非流式组装同样补 `created_at`/item id/status。单测 107/107（新增规范字段向量）、e2e 增至 **19 场景**
（新增 responses-wire：created_at / item.id / item_id / content_index / done.status / 非流式同套字段）。
TS 版同形状同步 → 0.1.8（102 单测，新增 tests/responses-wire.spec.ts）。

2026-10-20 静态审查修复（0.1.13）：① **网关令牌支持 `x-api-key` 载体**（Anthropic 标准客户端只发这个头，
此前配了 token 就永远 401；两种载体等价）；② **`response.failed` 与兜底 `response.completed` 补
`created_at`**（上一轮只补了 created/主 completed——审查抓到的遗漏；严格客户端 schema 校验下这类
缺字段会被整条丢弃）；③ 默认构建产物 `zig-out/bin/auto-compat` 重建到当前版本（此前残留 0.1.5，
容易被误当最新发行物）。单测 107/107、e2e 19 场景（新增 failed/completed 的 created_at 断言与
x-api-key 鉴权两项）全绿。TS 侧同轮修复见其 README（图片输入作用域/预算、断连传导、listen 错误、
端口与数值环境变量严格解析等）。

2026-10-25 日志可读性（0.1.14，真机排障）：① 换方言日志区分失败性质与时间预算——
`openai failed after retries (last HTTP 502 SERVER), mapping via responses (2/3 dialects tried)`；
若同方言重试因 20s 预算耗尽被跳过，会写 `failed (budget spent) (…)`（此前统一写 "unavailable"，
把 502 误读成"路由不存在"）。② **每个请求一行汇总**（成功/失败都有）：
`intern-ai/glm-5.3: responses->anthropic FAILED code=SERVER attempts=2 switches=1 40211ms` /
`… OK attempts=1 switches=0 1832ms`；已向客户端出帧后中断的流记 `code=MID_STREAM`。这样客户端
（zcode/dsh）的一次 turn 失败能与网关日志一一对应，不再出现"turn 失败但日志没有结论"。
单测 107/107、e2e 19 场景全绿（新增汇总行断言，换方言措辞断言同步）。

2026-10-25 上游 TLS 失败的可行动化（0.1.15，真机 `连接失败：TlsInitializationFailed`）：排查确认这是
Zig `std.http` 把上游 TLS 握手/证书校验的**所有**失败折叠成的错误名（证书过期/未生效、主机名不匹配、
CA 缺失、握手失败都叫它），不是"网关不支持 TLS"；同一二进制连 intern-ai 连续 5 次 HTTPS 全正常
（401，~80ms），属上游侧一次性的握手/证书问题。修法：该错误翻译成可行动文案（检查网关主机的
`date` 与 CA 存储、确认能直连上游，然后重试）并单独打一行日志；仍按 SERVER 归类（可重试），
方言环会照常换方言再试。单测 107/107、e2e 19 场景全绿。

2026-10-25 诊断日志加密（0.1.16，用户要求"多加点报错，好让我之后精确定位"）：每个请求现在有完整链条，
并用**请求 id**（客户端 `x-request-id` 优先，否则 `#r1` 自增）对齐并发/重试交错的日志：
```
#r2 POST /v1/responses
#r2 inbound responses model=glm-5.3 stream=1 msgs=2 system=412B tools=18 max_tokens=0
#r2 attempt 1/7 responses https://discovery-api.intern-ai.org.cn/v1
#r2 attempt 1 responses FAILED http=502 code=SERVER 1207ms msg=<上游错误摘要，压平换行、限长160>
#r2 attempt 2/7 openai https://discovery-api.intern-ai.org.cn/v1
#r2 attempt 2 openai ok 1832ms
#r2 intern-ai/glm-5.3: responses->openai OK attempts=2 switches=1 3040ms
```
新增：入站解析摘要（方言/模型/流式/消息数/系统提示字节/tools 数/max_tokens）、解析失败留痕
（`inbound parse failed: <error>`）、鉴权拒绝与 404 留痕、每次上游尝试的开始（序号/方言/URL）与
结束（HTTP 状态、code、耗时、上游错误原文摘要）、请求终态汇总带 `msg=`；`x-request-id` 透传进日志。
上游错误摘要只保留 160 字符并压平控制符（不打印 key/header）。单测 109/109（新增 diag 模块两组）、
e2e 19 场景全绿（新增诊断行与 x-request-id 贯穿断言）。

2026-10-25 流式 flush 修复（0.1.17，用户问"为什么哨兵没发给 zcode/没看到保活效果"）：真因不是哨兵没生成，
而是**生成后排进了连接缓冲却没 flush 到 socket**。Zig 的 `respondStreaming` 返回的 `BodyWriter` 有两级缓冲：
`writer`（16KB 攒帧）和 `http_protocol_output`（连接写缓冲）。原代码只调 `writer.flush()`，于是：
① 响应头在等待上游期间完全没发出；② 占位帧/真实帧都滞留，直到响应结束（或 16KB 满）才一起到达。
日志里的 `placeholder keepalive: injected` 只证明"调用过注入"，不代表"客户端收到"。
修法：新增 `http_util.flushBody`（先 `writer.flush()` 再 `flush()`），所有真实帧/占位帧/收尾帧统一走它；
三个流式 handler 在 `respondStreaming` 后立刻 flush 响应头并刷新 `last_write_ms`。
e2e 新增两条墙钟断言：响应头 <1s 到达、占位在静默期 <1.5s 到达且领先真实内容 ≥0.5s（此前只比较
字节顺序，旧实现也能通过）。单测 109/109；e2e 19 场景 **156 项断言**全绿。TS 版同样补 `res.flushHeaders()`
（Node 也会攒响应头到第一次 write），→ 0.1.10。
