# 罗网 Dragnet 规则订阅（rules-dist）

> generated_at: 2026-11-10T19:21:49Z · label: 2026-11-10
> 本目录由 `cmd/ruleexport` 自动生成，请勿手改。每周一 03:00 UTC 由 CI 自动重建（`.github/workflows/rules-dist.yml`），也可在 Actions 手动触发（workflow_dispatch）。

## 订阅地址

- 阻断（Clash classical）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/clash-classical.yaml`
- 阻断（Clash domain）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/clash-domain.yaml`
- 阻断（AdGuard）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/adguard.txt`
- 阻断（hosts）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/hosts`
- 例外/保护（Clash classical）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/allow/clash-classical.yaml`
- 例外/保护（AdGuard）: `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/allow/adguard.txt`

## 产物清单

| 文件 | 格式 | 条数 | 用途 |
|---|---|---:|---|
| clash-classical.yaml | Clash classical (yaml) | 227345 | mihomo / Clash Verge Rev rule-providers，DOMAIN-SUFFIX/DOMAIN 按来源语义 |
| clash-domain.yaml | Clash domain (yaml) | 227345 | mihomo behavior:domain 纯域名集（仅后缀语义，性能更好） |
| adguard.txt | AdGuard | 227345 | AdGuard Home / AdGuard 客户端「DNS 拦截列表」 |
| hosts | hosts | 227345 | 系统/路由器 hosts（精确匹配语义） |
| domains.txt | 纯域名 | 227345 | 阻断域名全集，供二次加工 |
| allow/clash-classical.yaml | Clash classical (yaml) | 65 | 保护/例外域名（防误杀，**必须放在阻断规则之前**） |
| allow/adguard.txt | AdGuard | 65 | 保护/例外域名（@@ 语法，保留 $important） |

## 来源与统计

来源: anti-AD.txt, AWAvenue.txt, hagezi-multi.txt, starter.txt

| 文件 | 角色 | 行数 | 解析 | 阻断 | 放行 | 丢弃 |
|---|---|---:|---:|---:|---:|---:|
| `anti-AD.txt` | block-source | 102516 | 102443 | 102395 | 48 | 65 |
| `AWAvenue.txt` | block-source | 987 | 972 | 972 | 0 | 4 |
| `hagezi-multi.txt` | block-source | 207315 | 207301 | 207301 | 0 | 0 |
| `starter.txt` | block-source | 89 | 65 | 65 | 0 | 0 |
| `protected-allow.txt` | allow-list | 36 | 17 | 0 | 17 | 0 |

合并: 去重移除 69696，保护排除 15，冗余收缩 13677，最终阻断 227345 / 例外 65（详见 `manifest.json`）。

## Clash Verge Rev / mihomo 配置示例

```yaml
rule-providers:
  dragnet-allow:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/allow/clash-classical.yaml
    path: ./rules/dragnet-allow.yaml
    interval: 86400
  dragnet-block:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/clash-classical.yaml
    path: ./rules/dragnet-block.yaml
    interval: 86400
  dragnet-block-domain:
    type: http
    behavior: domain
    format: yaml
    url: https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/clash-domain.yaml
    path: ./rules/dragnet-block-domain.yaml
    interval: 86400

rules:
  - RULE-SET,dragnet-allow,DIRECT   # 例外/保护先行，防误杀
  - RULE-SET,dragnet-block,REJECT   # classical 版（与下面 domain 版二选一）
  # - RULE-SET,dragnet-block-domain,REJECT   # domain 版（mihomo 下性能更好）
```

**顺序要求**：`dragnet-allow` 必须放在所有阻断 RULE-SET 之前——静态发布格式没有 `$important`，
例外规则靠先后顺序保证优先级。

## Surge / AdGuard Home

- **AdGuard Home**：设置 → 过滤器 → DNS 拦截列表 → 添加 `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/adguard.txt`；
  再把 `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/allow/adguard.txt` 加入「自定义过滤规则」来源（@@ 例外语法，优先于阻断）。
- **Surge**：无原生 AdGuard 语法支持，可用 `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/domains.txt` 经转换工具生成 .list，
  或使用支持 AdGuard 规则的模块加载 `https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/adguard.txt`。
- **hosts**：`https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist/hosts` 可直接合并到系统/路由器 hosts（`0.0.0.0 domain`）。

## 更新说明

- 每周一 03:00 UTC CI 自动重建并覆盖 `rules-dist` 分支与滚动 Release（tag: `rules`）。
- 构建管线: `scripts/build-rules-dist.sh`（三源 + 种子规则 → 归一/去重/保护排除/冗余收缩）。
- 完整性自检: 阻断域名总数 < 10000 时构建直接失败（防拉到空/坏源）。
