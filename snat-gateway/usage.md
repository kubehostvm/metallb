# MetalLB 使用记录

## 共享 EIP（多个 Service 共用同一 External IP）

通过 annotation `metallb.io/allow-shared-ip` 实现。

### 条件

1. 共享的 Service 必须有相同的 `metallb.io/allow-shared-ip` 值
2. 端口不冲突（不同 port 或不同 protocol）

### 示例

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
