// HaxShot 全量代码评审工作流
//
// 流程（与 meta.phases 一一对应）：
//   探索   deepseek 分 5 个方向并行读代码 → 合成一份项目地图
//   评审   deepseek 按 6 个维度（分层/过度设计/冗余/过度守卫/死代码/平台适配）全量评审 → 逐条反证
//   提案   deepseek 把“被反证确认”的问题整理成可执行优化提案
//   复核   gpt-5.6-luna 两个视角复核 → deepseek 修订 #1 → luna 再复核 → deepseek 修订 #2
//   汇总   完整性检查 + 落盘报告 + 汇总“需要用户拍板”的决策清单
//
// 设计约束（按用户要求）：
//   * 全程只出提案，**不改任何代码**；需要二选一/拍板的地方一律不自己决定，
//     记进 needsDecision/options，最后统一交给用户。
//   * 只读命令，不跑 build/test（项目 AGENTS.md 明确要求默认不跑测试、不反复重建）。
//
// 用法：
//   SubagentWorkflow({ name: 'hax-shot-code-review' })
//   SubagentWorkflow({ name: 'hax-shot-code-review', args: { project: '/path/to/repo', outDir: '/tmp/x', maxVerify: 30 } })

export const meta = {
  name: 'hax-shot-code-review',
  description:
    'HaxShot 全量代码评审：deepseek 探索→六维度全量评审→优化提案，gpt-luna 两轮复核，deepseek 两轮修订；只出提案不改代码，所有二选一留到最后给用户',
  whenToUse:
    '需要对 hax_shot 做一次全项目、全量代码的结构/分层/过度设计/冗余/过度守卫/死代码评审，并且不希望自动改代码时',
  phases: [
    { title: '探索', detail: '5 个方向并行读代码 + 合成项目地图' },
    { title: '评审', detail: '6 个维度全量评审，逐条反证' },
    { title: '优化提案', detail: 'deepseek 把确认的问题整理成可执行提案' },
    { title: 'luna 评审 #1', detail: 'gpt-5.6-luna 两个视角复核提案' },
    { title: '修订 #1', detail: 'deepseek 按第 1 轮意见修订提案' },
    { title: 'luna 评审 #2', detail: 'luna 复核修订结果与决策漏项' },
    { title: '修订 #2', detail: 'deepseek 第 2 轮修订' },
    { title: '汇总', detail: '完整性检查 + 生成报告与决策清单' },
  ],
}

// ---------------------------------------------------------------- 参数与常量
const PROJECT = (args && args.project) ? args.project : '/Users/hax/Documents/GitHub/hax_shot'
const OUT = (args && args.outDir) ? args.outDir : '/tmp/hax_shot-code-review'
const MAX_VERIFY = (args && args.maxVerify) ? args.maxVerify : 40
const DEEPSEEK = 'deepseek/deepseek-flash'
const LUNA = 'openai-codex/gpt-5.6-luna'

// 每个子代理都会读到的公共约束。子代理看不到主对话，所有背景都写在这里。
const COMMON = `
【项目】${PROJECT}
Flutter + Rust 写的常驻托盘截图工具，主力平台 macOS，同时支持 Linux / Windows。
关键背景：托盘宿主进程（tray-only，没有主窗口）+ 短生命周期 --capture 进程（全屏框选浮层、标注、
AI 对话面板）；原生能力走 Rust dylib（FFI），macOS 浮层窗口由 Swift Runner 控制；
AI 面板复用仓库内的 packages/plume_ai_chat 与 packages/gpt_markdown。

【硬性要求】
1. 只读。不要修改/创建/删除仓库里的任何文件；不要跑构建、测试、安装、打包命令
   （项目 AGENTS.md 明确要求默认不跑 flutter test / cargo test / xcodebuild，也不要反复 build）。
   允许：rg / fd / ls / cat / sed -n / wc / git log / git diff / git show / git ls-files。
2. 每条结论都要有证据：文件路径 + 行号（必要时附关键代码）。没读过的文件不要猜；
   拿不准的结论要显式说明“不确定”，并写清还缺什么信息。
3. 遇到“需要用户拍板 / 二选一 / 有取舍”的情况：不要自己选，也不要停下来问。
   写进 needsDecision=true，并在 options 里给出候选（通常 2 个），recommendation 里写你的倾向与理由。
   这些最后会统一交给用户决定。
4. 用中文；具体、可执行，禁止“建议优化结构”这类空话。
5. 全量优先：先用 rg --files 列出源码（排除 build/、.dart_tool/、node_modules、packages/*/build、
   .git/），尽量逐文件读完；在 coverage 字段里说明实际读了哪些、哪些没读（没读的要写出来，不要假装全覆盖）。
`

// ---------------------------------------------------------------- schemas
const MAP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['area', 'summary', 'modules', 'platformNotes', 'risks', 'keyFiles', 'coverage'],
  properties: {
    area: { type: 'string' },
    summary: { type: 'string', description: '这个方向 5-10 行的结论' },
    modules: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'purpose', 'files', 'entrypoints'],
        properties: {
          name: { type: 'string' },
          purpose: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          entrypoints: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    platformNotes: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    keyFiles: { type: 'array', items: { type: 'string' } },
    coverage: { type: 'string' },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['dimension', 'coverage', 'findings'],
  properties: {
    dimension: { type: 'string' },
    coverage: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'id', 'category', 'severity', 'file', 'evidence',
          'problem', 'whyBad', 'suggestion', 'needsDecision', 'options',
        ],
        properties: {
          id: { type: 'string', description: '形如 layering-1，全局唯一（用维度前缀）' },
          category: {
            type: 'string',
            enum: ['layering', 'over-design', 'duplication', 'over-guard', 'dead-code', 'platform', 'other'],
          },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          file: { type: 'string', description: '路径:行号' },
          evidence: { type: 'string', description: '关键代码片段或引用' },
          problem: { type: 'string' },
          whyBad: { type: 'string' },
          suggestion: { type: 'string' },
          needsDecision: { type: 'boolean' },
          options: { type: 'array', items: { type: 'string' } },
        },
      },
    },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'verdict', 'reason'],
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['real', 'false-positive', 'uncertain'] },
          reason: { type: 'string' },
          correction: { type: 'string', description: '判定为误报时，正确的理解是什么' },
        },
      },
    },
  },
}

const PROPOSAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['proposals'],
  properties: {
    proposals: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'id', 'title', 'findingIds', 'files', 'currentState', 'proposedChange',
          'priority', 'risk', 'behaviorChange', 'needsDecision', 'options', 'recommendation',
        ],
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          findingIds: { type: 'array', items: { type: 'string' } },
          files: { type: 'array', items: { type: 'string' } },
          currentState: { type: 'string' },
          proposedChange: { type: 'string', description: '具体到能照着改：改哪个文件、哪一段、改成什么' },
          priority: { type: 'string', enum: ['high', 'medium', 'low'] },
          risk: { type: 'string' },
          behaviorChange: { type: 'string', description: '无 / 有：具体描述' },
          needsDecision: { type: 'boolean' },
          options: { type: 'array', items: { type: 'string' } },
          recommendation: { type: 'string' },
        },
      },
    },
  },
}

const LUNA_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['lens', 'overall', 'reviews'],
  properties: {
    lens: { type: 'string' },
    overall: { type: 'string' },
    reviews: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['proposalId', 'verdict', 'issues', 'requiredChanges', 'needsDecision', 'options'],
        properties: {
          proposalId: { type: 'string' },
          verdict: { type: 'string', enum: ['accept', 'revise', 'reject'] },
          issues: { type: 'array', items: { type: 'string' } },
          requiredChanges: { type: 'array', items: { type: 'string' } },
          needsDecision: { type: 'boolean' },
          options: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    missing: { type: 'array', items: { type: 'string' }, description: '你认为漏掉的提案/风险' },
  },
}

const REVISED_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['round', 'changelog', 'proposals'],
  properties: {
    round: { type: 'string' },
    changelog: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['proposalId', 'action', 'detail'],
        properties: {
          proposalId: { type: 'string' },
          action: { type: 'string', enum: ['accepted', 'revised', 'dropped', 'kept-with-note'] },
          detail: { type: 'string' },
        },
      },
    },
    proposals: PROPOSAL_SCHEMA.properties.proposals,
  },
}

const CRITIC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['missing', 'unverified', 'notes'],
  properties: {
    missing: { type: 'array', items: { type: 'string' }, description: '没覆盖到的文件/模块/维度' },
    unverified: { type: 'array', items: { type: 'string' }, description: '结论里没有证据或没反证过的' },
    notes: { type: 'string' },
  },
}

const FINAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'reportPath', 'decisions', 'stats', 'notCovered'],
  properties: {
    summary: { type: 'string' },
    reportPath: { type: 'string' },
    decisions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'topic', 'why', 'options', 'recommendation', 'impact'],
        properties: {
          id: { type: 'string' },
          topic: { type: 'string' },
          why: { type: 'string' },
          options: { type: 'array', items: { type: 'string' } },
          recommendation: { type: 'string' },
          impact: { type: 'string' },
        },
      },
    },
    stats: {
      type: 'object',
      additionalProperties: false,
      required: ['findings', 'confirmed', 'proposals', 'decisions'],
      properties: {
        findings: { type: 'number' },
        confirmed: { type: 'number' },
        proposals: { type: 'number' },
        decisions: { type: 'number' },
      },
    },
    notCovered: { type: 'array', items: { type: 'string' } },
  },
}

// ---------------------------------------------------------------- 小工具
function chunk(list, size) {
  const out = []
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size))
  return out
}

function norm(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/[\s`'"“”‘’（）()【】\[\]，,。.：:；;、/\\|!！?？-]+/g, '')
}

function dedupeFindings(findings) {
  const kept = []
  const seen = new Set()
  for (const f of findings) {
    if (!f || !f.problem) continue
    const file = String(f.file || '').split(':')[0]
    const key = file + '|' + norm(f.problem).slice(0, 60)
    const loose = file + '|' + norm(f.problem).slice(0, 24)
    if (seen.has(key) || seen.has(loose)) continue
    seen.add(key)
    seen.add(loose)
    kept.push(f)
  }
  return kept
}

function bySeverity(a, b) {
  const rank = { high: 0, medium: 1, low: 2 }
  const ra = rank[a.severity] === undefined ? 3 : rank[a.severity]
  const rb = rank[b.severity] === undefined ? 3 : rank[b.severity]
  return ra - rb
}

function j(value, limit) {
  const text = JSON.stringify(value, null, 1)
  const max = limit || 24000
  return text.length > max ? text.slice(0, max) + '\n…（已截断）' : text
}

// ---------------------------------------------------------------- 阶段 1：探索
const AREAS = [
  {
    key: '入口与进程模型',
    focus: `入口、进程与窗口模型：lib/main.dart、lib/app.dart、lib/features/app/*、lib/features/window/*、
lib/features/onboarding/*、lib/native/*，以及三个平台的 Runner 入口
（macos/Runner/*.swift、linux/runner/*.cc、windows/runner/*.cpp）。
重点：托盘宿主进程与 --capture 进程各自负责什么、单实例锁、硬退出、窗口显示/隐藏/圆角/层级、
主循环与生命周期回调、Dart 与原生之间的事件与状态同步。`,
  },
  {
    key: '截图管线',
    focus: `截图与标注管线：lib/features/capture/*（capture_page、screenshot_canvas、annotation、
screenshot_exporter、capture_toolbar、selection_toolbar_placement、text_annotation_editor、
capture_session、capture_overlay_window、capture_permission_guide）、rust/src/*（lib.rs / macos.rs /
linux.rs）、macos/Runner/Capture*.swift。
重点：冻结画面 → 框选 → 标注 → 导出/复制/保存的完整链路；坐标与 DPI 换算（逻辑像素 vs 物理像素）；
权限检查与失败路径；工具条定位算法；Dart 与 Rust/Swift 的职责切分是否清晰。`,
  },
  {
    key: 'AI 面板与内部包',
    focus: `AI 能力：lib/features/ai/**（controllers / services / models / views / widgets）、
lib/features/window/panel_chrome.dart、lib/hax_colors.dart，以及内部包 packages/plume_ai_chat、
packages/gpt_markdown。
重点：UI 分层（page → sidebar → widget）、控制器/服务边界、流式与状态管理（GetX 用法）、
图片附件与剪贴板、设置持久化、Markdown/代码块渲染、字体与主题色的来源、
内部包与宿主 App 的耦合与重复（同一份 widget/样式是否两边各写了一套）。`,
  },
  {
    key: '平台适配与构建发布',
    focus: `三平台适配与构建发布：macos/（Configs、entitlements、Info.plist、Assets）、
linux/（CMakeLists、my_application.cc、desktop、hicolor 图标）、windows/、rust/（Cargo.toml、target）、
scripts/*.sh、packaging/、.github/workflows/、docs/macos-distribution.md、docs/packaging.md、
pubspec.yaml。
重点：平台分支（Platform.isX / #if / target_os）是否对称、是否有只在某平台成立的硬编码假设、
签名与权限（entitlements、TCC）、图标与字体等资源的生成流程、CI 与本地脚本的重复与漂移。`,
  },
  {
    key: '测试与文档一致性',
    focus: `test/* 与 docs/*（含 docs/development-guide.md、docs/ai.md、docs/icon-and-tray.md、
mvp.md、README.md）。
重点：每个测试守住的是什么契约、哪些模块完全没有测试；文档里描述的结构/行为与当前代码是否一致
（特别是已经被改掉但文档还写着旧做法的部分）；文档里记的“坑”是否仍然有效。`,
  },
]

phase('探索')
const areaResults = await parallel(
  AREAS.map(function (area) {
    return function () {
      return agent(
        COMMON +
          '\n【本次任务】探索方向：' + area.key + '\n' + area.focus +
          '\n\n请把这一块读清楚，产出：涉及的模块清单（名称/职责/关键文件/入口）、平台差异、你注意到的风险点。' +
          '不要在这里做评审结论，只要把事实和结构说清楚；发现的疑点写进 risks。',
        {
          label: '探索:' + area.key,
          phase: '探索',
          schema: MAP_SCHEMA,
          agentType: 'Plan',
          model: DEEPSEEK,
        },
      )
    }
  }),
)

const areaOk = areaResults.filter(Boolean)
log('探索完成：' + areaOk.length + '/' + AREAS.length + ' 个方向有结果')

phase('探索')
const projectMap = await agent(
  COMMON +
    '\n【本次任务】把下面 5 个方向的探索结果合成一份项目地图（去重、补交叉引用、指出矛盾）。\n' +
    'area=项目地图；modules 要覆盖全部主要模块；platformNotes 写三平台差异矩阵；' +
    'risks 写“结构层面值得评审关注的点”（供下一步评审用）；coverage 写这次合成依据了哪些方向的结论、' +
    '哪些方向缺失或互相矛盾。\n\n【各方向结果】\n' + j(areaOk, 40000),
  {
    label: '项目地图',
    phase: '探索',
    schema: MAP_SCHEMA,
    agentType: 'Plan',
    model: DEEPSEEK,
  },
)

const mapBrief = projectMap
  ? '【项目地图（供定位用）】\n' + j(projectMap, 16000)
  : '【项目地图缺失】请自行用 rg/fd 摸清结构再评审。'

// ---------------------------------------------------------------- 阶段 2：评审 + 反证
const DIMENSIONS = [
  {
    key: '分层与依赖',
    ask: `分层设计是否清晰：UI / 状态 / 服务 / 原生边界有没有越层调用、循环依赖、
全局单例（Get.put / static instance）滥用、窗口与进程职责边界混乱（例如 UI 里直接操作窗口管理器、
服务层直接依赖具体 widget、原生方法散落在多处调用）。指出具体文件与调用链。`,
  },
  {
    key: '过度设计与抽象',
    ask: `过度设计：为一次性需求引入的抽象层/接口/包装类、只有一个实现却抽的接口、
用不上的配置项与开关参数、“将来可能需要”的扩展点、为了通用而绕远路的参数传递、
过度的小文件拆分（读一个功能要跳 5 个文件）。注意区分“必要的解耦”和“多余的抽象”。`,
  },
  {
    key: '冗余与重复',
    ask: `冗余/重复设计：同一逻辑在多个地方各写一遍（Dart 与 Swift/Rust 之间、
packages 与宿主 App 之间、两个平台 Runner 之间）、可以合并的 helper、
重复定义的常量/颜色/文案/尺寸（例如窗口尺寸、关闭按钮、快捷键解析）、
近似但不一致的两份实现（容易继续漂移的那种，重点标出）。`,
  },
  {
    key: '过度守卫与防御性代码',
    ask: `过度守卫：不可能发生的分支、重复校验（上层已保证还层层再判）、
把异常吞掉只打日志的 try/catch、为兼容已删除平台/旧行为保留的回退路径、
无意义的 null/空集合检查、掩盖真实错误的默认值、日志噪声。
同时区分“真的需要防的边界（外部输入/系统 API/权限）”与“多余的防御”。`,
  },
  {
    key: '死代码与未使用',
    ask: `死代码：没有被引用的 widget/方法/字段/常量/参数、未使用的 import 与依赖（pubspec）、
注释掉的旧实现、只为旧方案保留的文件、文档里描述但已经删掉的东西。
判定“没被引用”时必须用 rg 找全调用点（含字符串 key、路由表、反射/动态调用、pubspec assets、
.github 与 scripts 里的引用），不确定的标 uncertain 而不是当成结论。`,
  },
  {
    key: '平台适配一致性',
    ask: `平台适配：macos/linux/windows 三个平台的分支是否对称（有没有一边改了另一边忘了）、
硬编码的平台假设（路径、权限、字体、快捷键、托盘行为、窗口层级）、
某平台独有的失败路径是否处理、“只在 macOS 测过”的隐患。
平台差异是有意为之还是历史遗留，要给出判断依据。`,
  },
]

phase('评审')
const reviewResults = await parallel(
  DIMENSIONS.map(function (dim) {
    return function () {
      return agent(
        COMMON +
          '\n' + mapBrief +
          '\n\n【本次任务】单一维度全量评审：' + dim.key + '\n' + dim.ask +
          '\n\n要求：把整个源码树在这个维度上过一遍（用 rg --files 列文件，逐个读关键文件），' +
          '不要只看项目地图。每条 finding 给出 文件:行、证据、问题、为什么是问题、建议；' +
          '需要用户拍板的写 needsDecision + options。coverage 里写明读了哪些文件、哪些没读。' +
          '宁缺毋滥：只报你能拿出证据的。',
        {
          label: '评审:' + dim.key,
          phase: '评审',
          schema: FINDINGS_SCHEMA,
          agentType: 'reviewer-heavy',
          model: DEEPSEEK,
        },
      )
    }
  }),
)

const rawFindings = reviewResults.filter(Boolean).flatMap(function (r) {
  return r.findings || []
})
const allFindings = dedupeFindings(rawFindings)
const ranked = allFindings.slice().sort(bySeverity)
const toVerify = ranked.slice(0, MAX_VERIFY)
if (ranked.length > toVerify.length) {
  log(
    'findings 共 ' + ranked.length + ' 条，只反证前 ' + toVerify.length +
      ' 条（按严重度）；其余 ' + (ranked.length - toVerify.length) + ' 条只在报告里原样列出（未反证）',
  )
}

const verifyBatches = chunk(toVerify, 5)
const verifications = await parallel(
  verifyBatches.map(function (batch, index) {
    return function () {
      return agent(
        COMMON +
          '\n【本次任务】逐条反证下面这些评审发现。默认它们是**错的**，先去代码里找反证；' +
          '找不到反证才判 real。特别检查：\n' +
          '(a) “没被引用/死代码”是否真的没有任何调用点（rg 全仓库 + 字符串 key + pubspec/CI/脚本引用）；\n' +
          '(b) “冗余/重复”两边是否真的语义相同（可能有细微差别，合并会改变行为）；\n' +
          '(c) “过度守卫”的分支是否其实是外部输入或系统 API 的真实边界；\n' +
          '(d) “平台分支冗余”是否另一个平台的 Runner 其实依赖它。\n' +
          '判定：real（证实）/ false-positive（误报，reason 里说明正确的理解）/ uncertain（证据不足）。\n' +
          'correction 只在 false-positive 时填。\n\n【待反证发现】\n' + j(batch, 24000),
        {
          label: '反证:' + (index + 1),
          phase: '评审',
          schema: VERIFY_SCHEMA,
          agentType: 'reviewer-heavy',
          model: DEEPSEEK,
        },
      )
    }
  }),
)

const verdictById = {}
verifications.filter(Boolean).forEach(function (v) {
  ;(v.verdicts || []).forEach(function (item) {
    if (item && item.id) verdictById[item.id] = item
  })
})

const confirmed = []
const rejected = []
const unverified = []
toVerify.forEach(function (f) {
  const verdict = verdictById[f.id]
  if (!verdict) unverified.push(f)
  else if (verdict.verdict === 'real') confirmed.push(f)
  else rejected.push({ finding: f, verdict: verdict })
})
log(
  '反证结果：确认 ' + confirmed.length + ' 条，误报 ' + rejected.length +
    ' 条，未出结论 ' + unverified.length + ' 条',
)

// ---------------------------------------------------------------- 阶段 3：优化提案
phase('优化提案')
const proposalGroups = chunk(confirmed, 12)
const proposalSets = await parallel(
  proposalGroups.map(function (group, index) {
    return function () {
      return agent(
        COMMON +
          '\n' + mapBrief +
          '\n【本次任务】把下面这些**已反证确认**的问题整理成可执行的优化提案。\n' +
          '要求：\n' +
          '1. 只出提案，**不要改任何文件**；提案要具体到“哪个文件、哪一段、现在是什么、改成什么”，' +
          '让人可以照着直接改。\n' +
          '2. 同一处/同一主题合并成一个提案，不要一条 finding 一个提案；提案的 findingIds 要能对上。\n' +
          '3. 不要引入新依赖、新抽象、新配置项；如果确实只有引入才能解决，把它标成 needsDecision 并给出选项。\n' +
          '4. priority 按“收益/风险”排序；behaviorChange 写清是否改变现有行为（含 UI 观感、存储格式、权限流程）。\n' +
          '5. 删代码类提案要说明“删掉后哪个功能/平台会受影响，怎么验证”。\n' +
          '6. 需要用户拍板的（例如“保留兼容分支 vs 直接删掉”“两个近似实现合并到哪一个”）' +
          '写 needsDecision + options + recommendation，不要自己定。\n\n【已确认问题】\n' + j(group, 24000),
        {
          label: '提案:' + (index + 1),
          phase: '优化提案',
          schema: PROPOSAL_SCHEMA,
          agentType: 'planner',
          model: DEEPSEEK,
        },
      )
    }
  }),
)

let proposals = proposalSets.filter(Boolean).flatMap(function (s) {
  return s.proposals || []
})
// 重新编号，保证跨批次唯一（findingIds 仍指向原 finding id）。
proposals = proposals.map(function (p, index) {
  p.id = 'P' + (index + 1)
  return p
})
log('优化提案：' + proposals.length + ' 条')

// ---------------------------------------------------------------- 阶段 4：luna 复核 #1
const LENSES = [
  {
    key: '正确性与风险',
    ask: `你的视角是“正确性与风险”：提案对代码现状的理解对不对？有没有误读上下文、漏看调用点、
把有意为之的设计当成缺陷？改完之后会不会破坏某个平台、某个状态（权限、浮层、进程退出、存储格式）？
有没有更安全的最小改法？`,
  },
  {
    key: '简洁性与过度设计',
    ask: `你的视角是“简洁性与过度设计”：提案本身是不是又引入了新的抽象、包装、配置项、兼容分支？
有没有更小、更直接、删得更多的改法？多个提案之间是否互相冲突或可以合并？
有没有提案其实是“为了优雅而优雅”，对用户价值和可维护性没有实际收益？`,
  },
]

function lunaPrompt(lens, currentProposals, round) {
  return (
    COMMON +
      '\n' + mapBrief +
      '\n【本次任务】你是复核者（' + round + '），视角：' + lens.key + '。\n' + lens.ask +
      '\n\n要求：不要只看提案文字，**去读对应代码**核对提案的前提是否成立；' +
      '逐条给出 accept / revise / reject，revise 要写清必须改什么（requiredChanges）。' +
      '发现提案漏掉的问题写进 missing。需要用户拍板的写 needsDecision + options，不要自己拍板。\n\n' +
      '【待复核提案】\n' + j(currentProposals, 26000)
  )
}

phase('luna 评审 #1')
const luna1 = await parallel(
  LENSES.map(function (lens) {
    return function () {
      return agent(lunaPrompt(lens, proposals, '第 1 轮'), {
        label: 'luna:' + lens.key,
        phase: 'luna 评审 #1',
        schema: LUNA_SCHEMA,
        agentType: 'reviewer-heavy',
        model: LUNA,
      })
    }
  }),
)

function flattenLuna(results) {
  return results.filter(Boolean).flatMap(function (r) {
    return (r.reviews || []).map(function (item) {
      item.lens = r.lens
      return item
    })
  })
}

const luna1Items = flattenLuna(luna1)
const luna1Missing = luna1.filter(Boolean).flatMap(function (r) {
  return r.missing || []
})
log('luna 第 1 轮：' + luna1Items.length + ' 条逐项意见，漏项 ' + luna1Missing.length + ' 条')

// ---------------------------------------------------------------- 阶段 5：修订 #1
function revisePrompt(roundLabel, currentProposals, lunaItems, missing, changelogNote) {
  return (
    COMMON +
      '\n【本次任务】按复核意见修订提案（' + roundLabel + '）。\n' +
      '规则：\n' +
      '1. **不要改代码**，只更新提案文本；必须返回**完整**的修订后提案列表（不能只返回改动的那几条），' +
      'id 保持稳定（P1、P2…），被删掉的提案要在 changelog 里写 dropped 及原因。\n' +
      '2. 对 accept 的：保留，必要时把复核意见里明确的细节补进 proposedChange。\n' +
      '3. 对 revise 的：按 requiredChanges 改，改不动的（需要用户拍板/证据不足）转成 needsDecision + options。\n' +
      '4. 对 reject 的：把提案降级（改成 needsDecision 保留信息）或 dropped，说明理由。\n' +
      '5. 复核者指出的漏项、以及复核意见里新出现的二选一，合并成新的提案或决策项，仍然不要自己拍板。\n' +
      changelogNote +
      '\n\n【当前提案】\n' + j(currentProposals, 26000) +
      '\n【复核逐项意见】\n' + j(lunaItems, 16000) +
      '\n【复核指出的漏项】\n' + j(missing, 4000)
  )
}

phase('修订 #1')
let rev1 = await agent(revisePrompt('第 1 轮', proposals, luna1Items, luna1Missing, ''), {
  label: '修订 #1',
  phase: '修订 #1',
  schema: REVISED_SCHEMA,
  agentType: 'planner',
  model: DEEPSEEK,
})
if (rev1 && rev1.proposals && rev1.proposals.length) proposals = rev1.proposals
else log('修订 #1 没有返回可用提案，沿用原提案继续')

// ---------------------------------------------------------------- 阶段 6：luna 复核 #2
phase('luna 评审 #2')
const luna2 = await agent(
  lunaPrompt(
    {
      key: '残留问题与决策完整性',
      ask: `你的视角是“残留问题与决策完整性”：第 1 轮的意见是否真的被解决了（逐条核对 changelog 与提案正文）？
修订有没有引入新的过度设计或新风险？还有没有该删没删、该问没问的？
**特别检查决策清单是否完整**：凡是需要用户拍板/二选一的地方，是否都写成了 needsDecision + options，
有没有被悄悄“替用户决定”的地方（这是本次流程最不能接受的错误）。`,
    },
    proposals,
    '第 2 轮',
  ) + '\n【第 1 轮修订说明】\n' + j(rev1 ? rev1.changelog : [], 8000),
  {
    label: 'luna#2',
    phase: 'luna 评审 #2',
    schema: LUNA_SCHEMA,
    agentType: 'reviewer-heavy',
    model: LUNA,
  },
)
const luna2Items = flattenLuna([luna2])
const luna2Missing = (luna2 && luna2.missing) || []
log('luna 第 2 轮：' + luna2Items.length + ' 条意见，漏项 ' + luna2Missing.length + ' 条')

// ---------------------------------------------------------------- 阶段 7：修订 #2
phase('修订 #2')
let rev2 = await agent(
  revisePrompt(
    '第 2 轮',
    proposals,
    luna2Items,
    luna2Missing,
    '6. 这一轮是最后一轮：把仍然悬而未决的东西**全部**收敛成决策项（每项 2 个选项 + 你的倾向），' +
      '不要留下“待定”“建议进一步确认”这种模糊状态。',
  ),
  {
    label: '修订 #2',
    phase: '修订 #2',
    schema: REVISED_SCHEMA,
    agentType: 'planner',
    model: DEEPSEEK,
  },
)
if (rev2 && rev2.proposals && rev2.proposals.length) proposals = rev2.proposals
else log('修订 #2 没有返回可用提案，沿用上一版提案继续')

// ---------------------------------------------------------------- 阶段 8：汇总
phase('汇总')
const critic = await agent(
  COMMON +
    '\n【本次任务】完整性检查（critic）。下面是这次评审的全部产物摘要。请回答：\n' +
    '1. 有没有整块没被评审到的地方（文件/模块/维度）？用 rg --files 对照一下源码清单。\n' +
    '2. 有哪些结论是**没有证据**或没有经过反证的？\n' +
    '3. 有哪些地方其实需要用户拍板，但被写成了“建议/待定”而没有进决策清单？\n' +
    '只列真问题，不要凑数。\n\n' +
    '【项目地图】\n' + j(projectMap, 8000) +
    '\n【确认的问题】\n' + j(confirmed.map(compactFinding), 12000) +
    '\n【误报（已排除）】\n' + j(rejected.map(function (r) { return compactFinding(r.finding) }), 6000) +
    '\n【最终提案】\n' + j(proposals, 20000),
  {
    label: '完整性检查',
    phase: '汇总',
    schema: CRITIC_SCHEMA,
    agentType: 'reviewer-heavy',
    model: DEEPSEEK,
  },
)

function compactFinding(f) {
  return {
    id: f.id,
    category: f.category,
    severity: f.severity,
    file: f.file,
    problem: f.problem,
    suggestion: f.suggestion,
    needsDecision: f.needsDecision,
    options: f.options,
  }
}

const decisionsFromFindings = confirmed
  .filter(function (f) { return f.needsDecision })
  .map(function (f) { return { id: f.id, topic: f.problem, options: f.options || [] } })
const decisionsFromProposals = proposals
  .filter(function (p) { return p.needsDecision })
  .map(function (p) { return { id: p.id, topic: p.title, options: p.options || [] } })
const decisionsFromLuna = luna1Items.concat(luna2Items)
  .filter(function (item) { return item.needsDecision })
  .map(function (item) { return { id: item.proposalId, topic: item.issues.join('；') || item.lens, options: item.options || [] } })

const finalReport = await agent(
  COMMON +
    '\n【本次任务】生成最终评审报告并落盘。你是唯一被允许写文件的环节，且**只允许写 ' + OUT +
    ' 目录下的文件**：不要修改仓库里的任何文件，不要跑构建。\n' +
    '请创建目录并写入：\n' +
    '  00-项目地图.md\n  01-评审发现.md（分维度，含证据、误报与排除理由、未反证清单）\n' +
    '  02-优化提案（终版）.md（每条含：现状/改法/影响/风险/是否改行为/优先级/相关 finding）\n' +
    '  03-复核记录.md（luna 两轮意见与两轮修订 changelog）\n' +
    '  04-待你决定.md（**最重要**：把所有 needsDecision 合并去重成一份清单，每条 2 个选项 + 倾向 + 影响，' +
    '并明确写“以上不做任何自动修改，等你决定”）\n  05-未覆盖与不确定.md\n' +
    'reportPath 返回 04-待你决定.md 的路径。\n' +
    'decisions 字段返回合并去重后的决策清单（最多 12 条，按重要性排序）。summary 写 10-20 行总览。\n' +
    'notCovered 写这次没覆盖到的地方（含 critic 指出的）。\n' +
    '**不要替用户做决定**：所有取舍都留在 04 里。\n\n' +
    '【统计】findings 原始 ' + ranked.length + ' 条，反证确认 ' + confirmed.length +
    ' 条，误报 ' + rejected.length + ' 条，未出结论 ' + unverified.length +
    ' 条；提案 ' + proposals.length + ' 条。\n' +
    '【项目地图】\n' + j(projectMap, 10000) +
    '\n【确认的问题】\n' + j(confirmed.map(compactFinding), 16000) +
    '\n【误报与排除理由】\n' + j(rejected.map(function (r) {
      return { finding: compactFinding(r.finding), verdict: r.verdict.reason, correction: r.verdict.correction }
    }), 8000) +
    '\n【未出结论（未反证）】\n' + j(unverified.map(compactFinding), 8000) +
    '\n【最终提案】\n' + j(proposals, 24000) +
    '\n【luna 两轮意见】\n' + j(luna1Items.concat(luna2Items), 12000) +
    '\n【两轮修订 changelog】\n' + j([rev1 ? rev1.changelog : [], rev2 ? rev2.changelog : []], 8000) +
    '\n【完整性检查】\n' + j(critic, 6000) +
    '\n【决策项候选（已收集，需你去重合并）】\n' + j({
      fromFindings: decisionsFromFindings,
      fromProposals: decisionsFromProposals,
      fromLuna: decisionsFromLuna,
    }, 12000),
  {
    label: '最终报告',
    phase: '汇总',
    schema: FINAL_SCHEMA,
    agentType: 'worker',
    model: DEEPSEEK,
  },
)

// ---------------------------------------------------------------- 返回
return {
  outDir: OUT,
  reportPath: finalReport ? finalReport.reportPath : null,
  summary: finalReport
    ? finalReport.summary
    : '最终汇总环节没返回结果；下面是各阶段原始统计与决策候选。',
  stats: {
    findingsRaw: ranked.length,
    verified: toVerify.length,
    confirmed: confirmed.length,
    falsePositive: rejected.length,
    unverified: unverified.length,
    proposals: proposals.length,
    lunaRound1: luna1Items.length,
    lunaRound2: luna2Items.length,
    droppedFromVerify: ranked.length - toVerify.length,
  },
  decisions: finalReport && finalReport.decisions ? finalReport.decisions : [],
  decisionCandidates: {
    fromFindings: decisionsFromFindings,
    fromProposals: decisionsFromProposals,
    fromLuna: decisionsFromLuna,
  },
  notCovered: finalReport && finalReport.notCovered ? finalReport.notCovered : [],
  critic: critic,
  proposals: proposals,
  confirmedFindings: confirmed.map(compactFinding),
  // 过程产物（备查；不写文件，只回传摘要）
  provenance: {
    areas: areaOk.map(function (a) { return a.area }),
    dimensions: reviewResults.filter(Boolean).map(function (r) { return r.dimension }),
    lunaModels: LUNA,
    deepseekModel: DEEPSEEK,
    note: '本次运行只产出提案，没有修改任何代码；所有取舍都在 decisions 里等用户决定。',
  },
}
