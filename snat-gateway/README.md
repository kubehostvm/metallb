# MetalLB SNAT Gateway

在 Calico IPIP 环境中，基于 MetalLB 的 LoadBalancer 机制，为 Pod 出站流量添加 SNAT（源地址转换为 LB 的 External IP）。

## 文件结构

```
snat-gateway/
├── Dockerfile          # 轻量镜像：alpine + bash/iptables/jq/kubectl
├── snat-gateway.sh     # 核心 SNAT 管理脚本
├── deploy.yaml         # ServiceAccount + RBAC + DaemonSet（ConfigMap 挂载脚本）
└── README.md
```

## 架构

```
MetalLB (已有，不修改)          snat-gateway (新增 DaemonSet)
┌──────────────────────┐       ┌─────────────────────────────────┐
│ Controller: 分配 EIP  │       │ 每 10s 轮询 K8s API:             │
│ Speaker:   宣告 EIP   │       │   Service(type=LB) → EIP        │
│ kube-proxy: DNAT     │       │   EndpointSlice → 本节点 PodIP   │
│                      │       │                                 │
│ 入站: EIP → DNAT → Pod│       │ 出站: PodIP → SNAT → EIP         │
└──────────────────────┘       │                                 │
                               │ iptables -t nat chain:          │
                               │   METALLB_SNAT (挂在 POSTROUTING)│
                               │   -s PodIP/32 -o eth0           │
                               │   -j SNAT --to-source EIP       │
                               └─────────────────────────────────┘
```

## 脚本核心逻辑（reconcile 循环）

1. `kubectl get svc -A` + `kubectl get endpointslices -A`，用 jq 关联出 `{podIP → EIP}` 映射（只取本节点 ready endpoint）
2. `iptables-save -t nat | grep METALLB_SNAT` 解析当前规则
3. Diff：缺的加（`add_snat`），多的删（`del_snat`）
4. SIGTERM 时清除所有规则和自定义 chain

## Pod 模板设计

基于 kube-ovn vpc-nat-gw Pod 模板风格：

- `hostNetwork: true` + `privileged: true`（操作宿主机 iptables）
- `dnsPolicy: ClusterFirstWithHostNet`
- `postStart: sysctl -w net.ipv4.ip_forward=1`
- 脚本通过 **ConfigMap** 挂载到 `/snat-gateway/`（更新脚本无需重建镜像）
- RBAC 只读 `services` 和 `endpointslices`

## 部署步骤

```bash
cd snat-gateway/

# 1. 构建镜像
docker build -t metallb-snat-gateway:latest .

# 2. 创建 ConfigMap（脚本内容）
kubectl create configmap metallb-snat-gateway-script \
  --from-file=snat-gateway.sh \
  -n metallb-system

# 3. 部署
kubectl apply -f deploy.yaml

# 更新脚本时：
kubectl create configmap metallb-snat-gateway-script \
  --from-file=snat-gateway.sh \
  -n metallb-system --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart daemonset/metallb-snat-gateway -n metallb-system
```

## 已知限制

**L2 模式**：SNAT 回包只能到达 ARP 选举节点。Pod 必须调度在 EIP 所属节点上，否则回包无法到达发起 SNAT 的节点。BGP 模式无此限制。
