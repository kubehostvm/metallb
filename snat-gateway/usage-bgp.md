# MetalLB BGP 模式部署指南

## 三种 BGP 实现

| 模式 | `METALLB_BGP_TYPE` | 部署清单 | 说明 |
|------|-------------------|---------|------|
| **native** | 不设置（默认） | `metallb-native.yaml` | MetalLB 内置 BGP 实现，功能有限 |
| **frr** | `frr` | `metallb-frr.yaml` | **推荐**。Speaker Pod 内运行 FRR 容器，功能完整 |
| frr-k8s | `frr-k8s` | `metallb-frr-k8s.yaml` | FRR 作为独立 DaemonSet 部署，适合与其他 FRR 使用者共存 |

推荐使用 `frr` 模式：支持 BFD、ECMP、Graceful Restart、VRF、eBGP Multi-hop 等完整功能。

## 部署差异

**native 模式**：Speaker DaemonSet 只有 1 个容器（speaker）

**frr 模式**：Speaker DaemonSet 有多个容器：
- `speaker` — MetalLB speaker（`METALLB_BGP_TYPE=frr`）
- `frr` — FRR 路由套件（`quay.io/frrouting/frr:10.5.1`）
- `frr-metrics` — FRR metrics 导出
- `reloader` — FRR 配置热加载

## 需要创建的 CRD 资源

### 1. IPAddressPool（与 L2 模式相同）

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: eip-pool1
  namespace: metallb-system
spec:
  addresses:
    - 10.34.251.210-10.34.251.250
```

### 2. BGPPeer（定义 BGP 邻居）

```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: router1
  namespace: metallb-system
spec:
  myASN: 64512        # 本端 ASN
  peerASN: 64512       # 对端 ASN（相同=iBGP，不同=eBGP）
  peerAddress: 10.34.251.1  # 对端路由器 IP
  # peerPort: 179      # 默认 179
  # sourceAddress: 10.34.251.21  # 可选，指定源地址
  # ebgpMultiHop: true  # eBGP 多跳（仅 FRR 模式）
  # bfdProfile: fast    # 可选，关联 BFD 快速故障检测
  # nodeSelectors:      # 可选，只在指定节点建立 BGP
  #   - matchLabels:
  #       role: bgp-speaker
```

### 3. BGPAdvertisement（定义路由通告策略）

```yaml
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: eip-adv
  namespace: metallb-system
spec:
  # ipAddressPools:       # 空 = 所有 pool
  #   - eip-pool1
  # aggregationLength: 32  # 默认 /32，可改为 /24 聚合路由
  # localPref: 100         # 本地优先级（iBGP）
  # communities:           # BGP community
  #   - 65535:65282
  # nodeSelectors:         # 只从指定节点通告
  #   - matchLabels:
  #       role: bgp-speaker
```

### 4. BFDProfile（可选，快速故障检测）

```yaml
apiVersion: metallb.io/v1beta1
kind: BFDProfile
metadata:
  name: fast
  namespace: metallb-system
spec:
  receiveInterval: 300    # ms
  transmitInterval: 300   # ms
  detectMultiplier: 3     # 3次未收到 = 判定故障（900ms）
```

## Calico 环境推荐配置

已有 Calico（使用 BGP），建议与 Calico 使用同一 ASN：

```yaml
# BGPPeer - 指向网关/路由器
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: gateway
  namespace: metallb-system
spec:
  myASN: 64512
  peerASN: 64512          # 与 Calico 使用同一 ASN（iBGP）
  peerAddress: 10.34.251.1 # 网关 IP，需要根据实际调整
---
# BGPAdvertisement - 通告所有 pool
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: eip-adv
  namespace: metallb-system
```

## BGP vs L2 对比

| | L2 | BGP |
|---|---|---|
| EIP 通告节点数 | 只有 1 个（选举 winner） | **所有节点**（ECMP） |
| SNAT 回包 | 只能回到 owner 节点 | 路由器 ECMP 可到任意节点 |
| 故障切换 | Gratuitous ARP + 交换机 MAC 表更新 | BGP 路由收敛（秒级，BFD 可达亚秒） |
| 需要 `externalTrafficPolicy: Local` | SNAT 场景必须 | 不强制要求 |
| 网络设备要求 | 无（纯二层） | 需要上游路由器支持 BGP |
