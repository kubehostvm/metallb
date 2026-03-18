# MetalLB 使用记录

## 共享 EIP（多个 Service 共用同一 External IP）

通过 annotation `metallb.io/allow-shared-ip` 实现。

### 条件

| 条件 | 来源 | 说明 |
|------|------|------|
| sharing key 相同 | `metallb.io/allow-shared-ip` annotation 的值 | 跨 namespace 只要值相同即可 |
| backend key 相同 | `externalTrafficPolicy: Cluster` 时为空（自动匹配）；`Local` 时为 selector 字符串 | Cluster 模式下自动满足 |
| 端口不冲突 | Service 的 port + protocol | 不同端口或不同协议 |

**支持跨 namespace 共享**：校验逻辑（`internal/allocator/allocator.go:612 sharingOK`）不涉及 namespace，只校验以上三个条件。

注意：如果用 `externalTrafficPolicy: Local`，两个 Service 的 Pod selector 必须完全相同（backend key 一致），否则共享会被拒绝。用 `Cluster` 模式则无此限制。

### 同 namespace 示例

```yaml
# Service A - TCP:80
apiVersion: v1
kind: Service
metadata:
  name: svc-a
  annotations:
    metallb.io/allow-shared-ip: "my-shared-group"
spec:
  type: LoadBalancer
  ports:
    - port: 80
      protocol: TCP

# Service B - TCP:443（共享同一个 EIP）
apiVersion: v1
kind: Service
metadata:
  name: svc-b
  annotations:
    metallb.io/allow-shared-ip: "my-shared-group"
spec:
  type: LoadBalancer
  ports:
    - port: 443
      protocol: TCP
```

### 跨 namespace 示例

```yaml
# namespace: app-a
apiVersion: v1
kind: Service
metadata:
  name: svc-http
  namespace: app-a
  annotations:
    metallb.io/allow-shared-ip: "shared-eip-1"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  ports:
    - port: 80

# namespace: app-b（不同 namespace，共享同一 EIP）
apiVersion: v1
kind: Service
metadata:
  name: svc-https
  namespace: app-b
  annotations:
    metallb.io/allow-shared-ip: "shared-eip-1"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  ports:
    - port: 443
```

两个 Service 会分配到同一个 External IP，各自处理不同端口的流量。

## EIP 亲和（EIP 跟随 Pod 所在节点）

通过 `externalTrafficPolicy: Local` 实现。

### Kubernetes externalTrafficPolicy 对比

| | `Cluster`（默认） | `Local` |
|---|---|---|
| 流量转发 | 可转发到任意节点的 Pod | 只转发到本节点的 Pod |
| 负载均衡 | 跨所有 Pod 均匀分配 | 只在本节点 Pod 间分配 |
| 源 IP 保留 | 不保留（SNAT 为节点 IP） | **保留客户端真实源 IP** |
| Pod 不在本节点 | 正常工作（跨节点转发） | 流量丢弃（健康检查失败） |

### MetalLB L2 模式下的 EIP 宣告范围

| `externalTrafficPolicy` | EIP 宣告节点范围 | 行为 |
|---|---|---|
| `Cluster`（默认） | 所有有 speaker 的节点 | 按 hash 选举一个节点宣告，Pod 可能不在该节点 |
| **`Local`** | **只有运行了 Pod（endpoint）的节点** | EIP 一定在 Pod 所在节点宣告 |

代码逻辑在 `speaker/layer2_controller.go:103`：
```go
if svc.Spec.ExternalTrafficPolicy == v1.ServiceExternalTrafficPolicyTypeLocal {
    availableNodes = nodesWithEndpoint(eps, speakerMap)
}
```

### 示例

```yaml
apiVersion: v1
kind: Service
metadata:
  name: lb-snat-ng-svc
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local  # EIP 跟随 Pod
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: lb-snat-ng
```

### IPVS 模式下 Local 策略的集群内访问限制

当 kube-proxy 使用 IPVS 模式时，所有节点的 `kube-ipvs0` 上都会添加 EIP（如 `10.34.251.210/32`）。
这导致集群节点访问 EIP 时流量被本地 IPVS 截获，而非走网络到 owner 节点。

| 来源 | 是否正常 | 原因 |
|------|---------|------|
| Pod 所在节点 | 通 | IPVS 找到本地 endpoint |
| **集群外部客户端** | **通** | 流量走网络 → ARP → owner 节点 → 本地有 Pod |
| 其他集群节点 | 不通 | IPVS 截获，本地无 endpoint |

`externalTrafficPolicy: Local` 是为**外部流量**设计的，集群内跨节点访问 EIP 不通是预期行为。集群内部应使用 ClusterIP 访问服务。

### 对 SNAT 的意义

设置 `externalTrafficPolicy: Local` 后，EIP 的 owner 节点一定是 Pod 所在节点。
SNAT 的回包通过 conntrack 在同一节点完成反向转换，彻底解决 L2 模式下回包到错误节点的问题。

## EIP 漂移机制（L2 模式）

### 选举算法

EIP owner 由 `SHA256(nodeName + "#" + eipString)` 排序决定，排第一的节点获胜（`speaker/layer2_controller.go:119-128`）。

选举结果只取决于 **`availableNodes` 列表**和 **EIP 本身**。EIP 不变时，只有 `availableNodes` 变化才触发漂移。

### 触发漂移的 5 种情况

| 触发条件 | 代码路径 | 机制 |
|----------|---------|------|
| **1. Speaker Pod 崩溃/重启** | Memberlist `NodeLeave` → `ForceSync()` → 重新处理所有 Service | 节点从 `availableNodes` 中移除 |
| **2. 节点 NotReady（网络不可用）** | `SetNode()` → `isNodeAvailableChanged()` → `SyncStateReprocessAll` | `IsNetworkUnavailable` 变为 true，被 `speakersForPool` 排除 |
| **3. 节点加标签 `exclude-from-external-load-balancers`** | `SetNode()` → `isNodeAvailableChanged()` → `SyncStateReprocessAll` | 被 `speakersForPool` 排除 |
| **4. Endpoint 变化（仅 `externalTrafficPolicy: Local`）** | EndpointSlice 变更触发 Service reconcile | Pod 迁移/删除后，`nodesWithEndpoint` 返回不同节点 |
| **5. L2Advertisement/IPAddressPool 配置变更** | Config reconcile → `SyncStateReprocessAll` | `poolMatchesNodeL2` 匹配结果变化 |

### 不会触发漂移的情况

- Service 的端口、selector 等变更（不影响 `availableNodes`）
- Pod 重建但调度到**同一节点**（`availableNodes` 不变）
- 节点资源压力（CPU/内存不足不影响 Memberlist 和 Node condition）

### 关键特性

- **确定性选举**：相同的 `availableNodes` + 相同的 EIP = 相同的 winner（SHA256 hash 排序）
- **Gratuitous ARP**：漂移后新 owner 发送免费 ARP（`internal/layer2/arp.go:54`），通知交换机更新 MAC 表
- **快速故障检测**：Memberlist 秒级检测 Speaker 故障，比 Kubernetes Node condition 更新（分钟级）更快
