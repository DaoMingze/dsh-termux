---
template_version: 0.5.6
template_status: stable
---

# 文档索引

本目录只收**散文文档**。术语见根 `GLOSSARY.md`（专用层由项目手改维护；模板只给初始骨架，`sync`／`update` 保留手改）；领域模型与决策记录见 `decision/`。

## 桶——每个桶回答一个问题

|桶|回答的问题|边界判据|
|---|---|---|
|`needs/`|为什么做、为谁做、解决什么问题|写不出消费者与场景就不属于需求；不写怎么实现|
|`design/`|系统怎么组成、模块边界与接口|描述实现结构；不承载取舍理由|
|`decision/`|在什么约束下选了哪条路、代价是什么|一项代价陡峭的取舍一篇，含被否候选与代价|
|`research/`|还不知道什么、有哪些候选与依据|给证据，不代表最终裁定|
|`delivery/`|怎么施工、怎么证明做成了|含每步判据与验收判据；不记施工流水账|
|`operations/`|怎么构建、发布、升级、诊断、恢复|交付后的动作面|
|`lesson/`|哪些经验值得复用|跨项目可迁移；与既有方法／纪律同源处以 `METHODOLOGY.md`／`RULES.md` 为准，不复制其条文|

桶名口径与例外清单见 [`../conventions/naming/README.md`](../conventions/naming/README.md)。

桶目录由项目自建（`sync` 只产出本文件，不建桶）：`mkdir needs design decision research delivery operations lesson`。

桶内可建生命周期子目录（如 `delivery/archive/`）承载过期文档；它们仍要登记在项目自建的 `index.md`，不删——归档表达生命周期，不表达失效。

## 文档类型后缀——同一桶内按变化频率分文件

|后缀|文档|术语|
|---|---|---|
|`-prd.md`|产品需求：为什么、为谁|`product_requirements_document`|
|`-spec.md`|需求规格：必须做什么、如何判定|未登记|
|`-plan.md`|实施方案：分步施工及每步判据|`implementation_plan`|
|`-verification.md`|验证方案：验收判据|`verification_plan`|
|`-review.md`|评审结果：结论及其依据|`review_results`|

不属于上表任何类型的文档（如操作手册、环境记录）**不加后缀**，用裸名，如 `operations/build-and-run.md`；后缀的作用是标出「这份文档回答哪类问题」，套不上就不套，不要自造后缀。

## `_inbox/`——兜底，不是分类

1. 只收当下无法归入既有桶的文档；
2. 每份文件必须在本项目文档登记里标 `（待归类）`；
3. 每个关口检查一次并归位（移出或删除），不留长期住户。

## 本项目文档登记

本文件是模板产物（`sync` 覆盖），**不要在这里写本项目的文档清单**：各项目自建 `./index.md` 做逐条登记，该文件不属模板产物、`sync` 不管。登记表最小要求：

- 一行一份文档，行内给出可点击的相对路径、所属桶，以及**一句话说明它回答什么问题**；
- **不写版本号，也不写状态**：版本看各文档 front-matter 的 `version`，状态看同一处的 `status`。这两样都只该有一份，登记表里再写一遍就是第二份，第二份必漂——典型形态是登记写"草案 0.1.5"而 front-matter 已到 0.1.12，且漂了不报错；
- 需要"版本／状态一览"时，用工具从 front-matter **派生**一张表，别手抄；没有派生工具就不要那张表（手抄的汇总表会被当成权威，比没有更糟）；
- 路径必须真实存在，未建的桶不占行、不写"将建于"；
- 不登记 `README.md`（模板产物，会被 `sync` 覆盖）与 `index.md` 自身（它就是登记表）。**派生表**（技能总览之类）可以登记，但只给路径与一句话：它没有自己的版本与状态，登记表也不该替它编一个。

`index.md` 不是模板产物，其 front-matter 与否由项目自定，**不受 `METHODOLOGY.md` §版本规范的必带字段约束**（那是给桶内文档的）；一旦选定，此后新增文档沿用同一形状。

桶内文档（`needs/`…`lesson/` 下的内容）**属于项目自有，不随模板分发**；约定类内容放根 `conventions/`（L1 约定树，随模板分发），不要把项目侧文档塞进约定树。

命令用法索引：`aisa` 各子命令、参数与退出码，见 [`../conventions/tooluse/README.md`](../conventions/tooluse/README.md)。

文档结构与行文规范的唯一出处见 [`../conventions/writing/`](../conventions/writing/)。
