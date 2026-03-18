# MetalLB BGP 模式部署指南

## 三种 BGP 实现

| 模式 | `METALLB_BGP_TYPE` | 部署清单 | 说明 |
|------|-------------------|---------|------|
| **native** | 不设置（默认） | `metallb-native.yaml` | MetalLB 内置 BGP 实现，功能有限 |
| **frr** | `frr` | `metallb-frr.yaml` | **推荐**。Speaker Pod 内运行 FRR 容器，功能完整 |
| frr-k8s | `frr-k8s` | `metallb-frr-k8s.yaml` | FRR 作为独立 DaemonSet 部署，适合与其他 FRR 使用者共存 |

推荐使用 `frr` 模式：支持 BFD、ECMP、Graceful Restart、VRF、eBGP Multi-hop 等完整功能。

## 架构差异

**Native 模式**（Speaker Pod 仅 1 个容器）：

```
Speaker Pod
└── speaker 容器
    └── Go 内置 BGP 实现（internal/bgp/native/）
        └── 直接用 Go 代码建立 TCP:179 连接，发送/解析 BGP 报文
```

**FRR 模式**（Speaker Pod 有 4 个容器）：

```
Speaker Pod
├── frr 容器          — FRR 路由套件（bgpd/zebra/bfdd），真正的 BGP 进程
├── reloader 容器     — 监听配置变更，热加载 FRR 配置
├── frr-metrics 容器  — 从 FRR vtysh 导出 Prometheus metrics
└── speaker 容器      — MetalLB speaker（生成 FRR 配置文件，通过 reloader 应用）
    └── METALLB_BGP_TYPE=frr
```

## 功能对比

| 功能 | Native | FRR |
|------|--------|-----|
| 基础 BGP（IPv4） | 支持 | 支持 |
| **IPv6 BGP** | **不支持** | 支持 |
| **BFD 快速故障检测** | **不支持** | 支持 |
| **Graceful Restart** | **不支持** | 支持 |
| **eBGP Multi-hop** | **不支持** | 支持 |
| **VRF** | **不支持** | 支持 |
| **KeepaliveTime 配置** | **不支持** | 支持 |
| **ConnectTime 配置** | **不支持** | 支持 |
| **Dynamic ASN** | **不支持** | 支持 |
| **Unnumbered BGP（接口模式）** | **不支持** | 支持 |
| **Large/Extended Community** | **不支持**（仅 legacy） | 支持 |
| **Dual Stack Address Family** | **不支持** | 支持 |
| 同 VRF 不同 myASN | 支持 | **不支持**（同 VRF 必须 myASN 相同） |
| 不同 RouterID | 支持 | **不支持**（所有 peer 必须 RouterID 相同） |

代码证据：`internal/config/validation.go:33-72`，native 模式拒绝所有 FRR-only 功能。

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

## BGP vs L2 对比

| | L2 | BGP |
|---|---|---|
| EIP 通告节点数 | 只有 1 个（选举 winner） | **所有节点**（ECMP） |
| SNAT 回包 | 只能回到 owner 节点 | 路由器 ECMP 可到任意节点 |
| 故障切换 | Gratuitous ARP + 交换机 MAC 表更新 | BGP 路由收敛（秒级，BFD 可达亚秒） |
| 需要 `externalTrafficPolicy: Local` | SNAT 场景必须 | 不强制要求 |
| 网络设备要求 | 无（纯二层） | 需要上游路由器支持 BGP |

## Calico IPIP 环境集成（重要）

### 核心问题：MetalLB BGP 与 Calico BGP 不能共存

问题不只是端口 179 冲突，而是 **BGP 协议本身的限制**：每对节点之间只允许一个 BGP session。
Calico BIRD 已经占用了 TCP:179 和到上游路由器的 BGP session。

实际验证：
```
# 所有节点的 BIRD 已占用 179 端口
xs4772: tcp LISTEN 0.0.0.0:179 users:(("bird",pid=41168,fd=7))
xs4773: tcp LISTEN 0.0.0.0:179 users:(("bird",pid=22886,fd=7))
xs4774: tcp LISTEN 0.0.0.0:179 users:(("bird",pid=19851,fd=7))
```

**结论：Native BGP 和 FRR BGP 都不能直接用。**

### 推荐方案：Calico 通告 MetalLB 分配的 EIP（Calico 3.18+）

MetalLB 官方推荐方案（参考 https://metallb.io/configuration/calico/ ）：
**MetalLB 只负责分配 IP，不做 BGP 通告。Calico 负责 BGP 通告。**

#### 1. MetalLB 侧：只配 IPAddressPool，不配 BGPAdvertisement

```yaml
# 只需要这一个资源，不要创建 BGPAdvertisement
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: eip-pool1
  namespace: metallb-system
spec:
  addresses:
    - 10.34.251.210-10.34.251.250
```

#### 2. Calico 侧：配置通告 LB IP

```bash
# 逐个 IP 通告（精确路由）
calicoctl patch BGPConfig default --patch \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "10.34.251.210/32"}, {"cidr": "10.34.251.211/32"}]}}'

# 或通告整个段（注意：Calico 会通告整个 CIDR，不是逐个 IP）
calicoctl patch BGPConfig default --patch \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "10.34.251.0/24"}]}}'
```

#### 3. 可选：移除 Speaker DaemonSet 节省资源

Controller 负责 IP 分配，Speaker 负责通告。如果 Calico 接管了通告，Speaker 可以不需要。
但如果还要保留 L2 模式作为备选，就保留 Speaker。

### 方案对比总结

| 方案 | 端口冲突 | 复杂度 | 功能 |
|------|---------|--------|------|
| **Calico 通告 EIP（推荐）** | 无 | 低 | MetalLB 分配 + Calico BGP 通告 |
| MetalLB L2 模式 | 无 | 低 | 不需要 BGP，但 SNAT 受限于 owner 节点 |
| MetalLB FRR/Native BGP | **有（不可行）** | - | BGP session 冲突，无法使用 |
| Spine 路由器方案 | 无 | 高 | MetalLB 对接 spine 而非 ToR，绕过冲突 |

## MetalLB + Calico BGP 集成原理

参考：https://docs.tigera.io/calico/latest/networking/configuring/advertise-service-ips

### 完整数据流

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes 集群                                  │
│                                                                         │
│  ┌──────────────┐    ①分配EIP     ┌──────────────────────┐              │
│  │   MetalLB    │ ──────────────→ │  Service             │              │
│  │  Controller  │  写入 status.   │  type: LoadBalancer   │              │
│  │              │  loadBalancer.  │  EIP: 10.34.251.210  │              │
│  └──────────────┘  ingress       └──────────┬───────────┘              │
│                                              │                          │
│                                   ②kube-proxy 监听到 EIP               │
│                                              │                          │
│                                              ▼                          │
│  ┌──────────────────────────────────────────────────────────┐          │
│  │                    每个节点                                │          │
│  │                                                          │          │
│  │  ┌──────────┐  ③IPVS规则    ┌──────────────────────┐    │          │
│  │  │kube-proxy│ ──────────→  │ IPVS: EIP:80 → PodIP │    │          │
│  │  └──────────┘  (DNAT)      └──────────────────────┘    │          │
│  │                                                          │          │
│  │  ┌──────────┐  ④BGP通告     ┌──────────────────────┐    │          │
│  │  │  Calico  │ ──────────→  │  BIRD: 向上游路由器     │    │          │
│  │  │  (BIRD)  │  EIP/32路由   │  通告 10.34.251.210/32│    │          │
│  │  └──────────┘              └──────────┬───────────┘    │          │
│  │                                        │                 │          │
│  └────────────────────────────────────────┼─────────────────┘          │
│                                           │                             │
└───────────────────────────────────────────┼─────────────────────────────┘
                                            │
                                   ⑤BGP 路由通告
                                            │
                                            ▼
                                 ┌────────────────────┐
                                 │   上游 ToR 路由器    │
                                 │                    │
                                 │  路由表:            │
                                 │  10.34.251.210/32  │
                                 │   → xs4772 (ECMP)  │
                                 │   → xs4773 (ECMP)  │
                                 │   → xs4774 (ECMP)  │
                                 └────────┬───────────┘
                                          │
                                 ⑥外部流量到达
                                          │
                                          ▼
                                 ┌────────────────────┐
                                 │   外部客户端         │
                                 │  curl 10.34.251.210 │
                                 └────────────────────┘
```

### 各组件职责分工

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  MetalLB Controller        Calico BIRD         kube-proxy   │
│  ┌─────────────┐          ┌─────────────┐    ┌───────────┐ │
│  │             │          │             │    │           │ │
│  │  IP 分配    │          │  BGP 通告    │    │  DNAT     │ │
│  │  (控制面)   │          │  (网络面)    │    │  (数据面)  │ │
│  │             │          │             │    │           │ │
│  │ IPAddressPool          │ BGPConfig   │    │ IPVS 规则  │ │
│  │ → 分配 EIP  │          │ → 通告 EIP  │    │ → 转发流量 │ │
│  │ → 写入 svc  │          │ → ECMP 多路 │    │ → 到 Pod   │ │
│  │   status    │          │ → BFD 检测  │    │           │ │
│  └─────────────┘          └─────────────┘    └───────────┘ │
│                                                             │
│  Speaker: 不需要（可选保留给 L2 备用）                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### externalTrafficPolicy 对 Calico BGP 通告的影响

```
externalTrafficPolicy: Cluster（默认）
┌────────────────────────────────────────────┐
│  所有节点都通告 EIP/32 路由                   │
│                                            │
│  xs4772 ──→ ToR: 10.34.251.210/32          │
│  xs4773 ──→ ToR: 10.34.251.210/32   (ECMP) │
│  xs4774 ──→ ToR: 10.34.251.210/32          │
│                                            │
│  ToR ECMP 分发到任意节点 → kube-proxy 转发   │
│  源 IP 不保留（SNAT 为节点 IP）               │
└────────────────────────────────────────────┘

externalTrafficPolicy: Local
┌────────────────────────────────────────────┐
│  只有 Pod 所在节点通告 EIP/32 路由            │
│                                            │
│  xs4773 ──→ ToR: 10.34.251.210/32（Pod在此）│
│  xs4772: 不通告                              │
│  xs4774: 不通告                              │
│                                            │
│  流量只到 Pod 节点 → 本地转发                  │
│  源 IP 保留                                  │
│  对 SNAT 友好：回包一定回到同一节点            │
└────────────────────────────────────────────┘
```

### 注意事项

- 上游 ToR 路由器需要支持 ECMP（等价多路径）才能实现负载均衡
- Calico `serviceLoadBalancerIPs` 通告的是整个 CIDR 块，不是逐个已分配 IP
- `externalTrafficPolicy: Local` 只适用于 LoadBalancer 和 NodePort 类型
