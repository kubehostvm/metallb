# SNAT 实现方案分析：Speaker 内集成 vs 独立 DaemonSet

## 结论：放在 Speaker 中实现更优

核心原因：**Speaker 已经拥有 SNAT 所需的全部关键信息，独立 DaemonSet 缺少一个关键信息。**

---

## 逐维度对比

### 1. 数据可用性（决定性差距）

| 所需信息 | Speaker 内部 | 独立 DaemonSet |
|---------|-------------|---------------|
| Service EIP | 已有 `c.svcIPs[name]` | 需 kubectl 查询 |
| 本节点 Pod endpoints | 已有 `epSlices` 回调参数 | 需 kubectl 查询 |
| **本节点是否是 EIP 的 owner** | **已有 `c.announced[proto][name]`** | **无法直接获取** |

第三项是关键。在 L2 模式下：

```go
// speaker/main.go:455 — Speaker 明确知道自己是否在通告某个服务
if !c.announced[protocol][name] {
    c.announced[protocol][name] = true
}
```

独立 DaemonSet 无法知道"本节点是否赢得了 L2 选举"，只能盲目在所有节点加 SNAT，导致非 owner 节点的 SNAT 回包无法到达。

### 2. 生命周期耦合

| 维度 | 放 Speaker | 独立 DaemonSet |
|------|-----------|---------------|
| Service 创建/删除 | 同步回调，零延迟 | 轮询，有 N 秒延迟 |
| Pod 漂移/重建 | EndpointSlice 回调驱动 | 轮询延迟 |
| EIP 发生 failover（L2 选举切换） | 立即感知，同步增删 SNAT | 感知不到，旧节点残留规则 |

Speaker 的 `SetBalancer` / `deleteBalancer` 是事件驱动的，SNAT 规则可以精确地与 EIP 宣告同步：

```
EIP 开始宣告 → 同时添加 SNAT 规则
EIP 停止宣告 → 同时删除 SNAT 规则
```

独立 DaemonSet 靠 `sleep 10` 轮询，在 failover 期间存在窗口期。

### 3. 架构影响

| 维度 | 放 Speaker | 独立 DaemonSet |
|------|-----------|---------------|
| 复杂度 | 需改 Go 代码，在 Protocol 接口附近加逻辑 | shell 脚本，简单 |
| Speaker 职责变化 | 从"网络面"扩展到"数据面"（iptables） | Speaker 不变 |
| 故障隔离 | SNAT bug 可能影响 Speaker 进程 | 完全隔离 |
| 资源开销 | 零额外 Pod | 每节点多一个 Pod + 重复 API 查询 |
| 可复用性 | 绑定 MetalLB | 可配合任意 LB 使用 |

### 4. 实现复杂度

**放 Speaker（Go）**：在 `SetBalancer` / `deleteBalancer` 路径中调用 iptables，约 100-150 行 Go 代码：

```go
// 伪代码 — 在 speaker/main.go handleService() 中
if c.announced[protocol][name] {
    snatManager.EnsureRule(podIPs, lbIPs, externalInterface)
}
// 在 deleteBalancerProtocol() 中
snatManager.DeleteRule(podIPs, lbIPs)
```

**独立 DaemonSet（shell）**：当前方案，约 150 行 bash + 额外部署资源。

---

## 建议路径

**当前阶段**：保留独立 DaemonSet 作为 MVP 快速验证功能。

**验证通过后**：迁移到 Speaker 内部实现。核心改动点：

1. `speaker/main.go` — 新增一个 `snatManager` 结构体，管理 iptables 规则
2. `handleService()` — EIP 开始通告时，为本节点的 endpoint Pod 添加 SNAT
3. `deleteBalancerProtocol()` — EIP 停止通告时，清除对应 SNAT
4. 通过 `c.announced[proto][name]` 精确控制只在 owner 节点做 SNAT

这样既解决了 L2 模式的 owner 问题，又实现了事件驱动的零延迟同步。
