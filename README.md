# 罗网 Dragnet

## 规则订阅发布（rules-dist）

本项目把规则资产（三源订阅 + 种子规则 `rules/starter.txt`，经保护清单 `rules/protected-allow.txt` 防误杀过滤）转换为其他 app 可用的格式，发布到孤儿分支 **`rules-dist`**，并附滚动 Release（tag `rules`）。产物由 `cmd/ruleexport` + `scripts/build-rules-dist.sh` 自动生成，**每周一 03:00 UTC** CI 自动重建（`.github/workflows/rules-dist.yml`），也可在 Actions 手动触发。

订阅地址前缀：`https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist`

| 产物 | 用途 |
|---|---|
| `clash-classical.yaml` | Clash classical 规则集（DOMAIN-SUFFIX/DOMAIN，按来源语义区分） |
| `clash-domain.yaml` | Clash.Meta `behavior: domain` 纯域名集（仅后缀语义域名，性能更好） |
| `adguard.txt` | AdGuard Home / AdGuard 客户端「DNS 拦截列表」（统一 `||domain^`） |
| `hosts` | `0.0.0.0 domain`，可直接合并系统/路由器 hosts |
| `domains.txt` | 阻断域名全集（纯域名，供二次加工） |
| `allow/clash-classical.yaml`、`allow/adguard.txt` | 保护/例外域名（防误杀，**必须放在阻断规则之前**） |
| `manifest.json`、`README.md` | 生成时间/来源统计/产物条数；面向各客户端的完整配置示例 |

Clash Verge Rev / mihomo 最小配置：

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

rules:
  - RULE-SET,dragnet-allow,DIRECT   # 例外/保护先行，防误杀
  - RULE-SET,dragnet-block,REJECT
```

AdGuard Home：拦截列表添加 `.../rules-dist/adguard.txt`，例外清单 `.../rules-dist/allow/adguard.txt` 加入自定义过滤规则。Surge 无原生 AdGuard 语法支持，可用 `domains.txt` 经转换工具生成 `.list`。

本地重建：`PROXY=http://127.0.0.1:7890 bash scripts/build-rules-dist.sh`（产物在 `build/rules-dist/`，含 manifest 与完整 README；GitHub 源需代理）。本地发布演练：`bash scripts/publish-rules-dist.sh --dry-run`。构建含完整性自检（阻断域名 < 10000 即失败）与保护排除/冗余收缩，口径为「宁可漏封不误封」。
