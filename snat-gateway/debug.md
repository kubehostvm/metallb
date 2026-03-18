# MetalLB 调试记录

## 问题 1：Speaker 不宣告 EIP

### 现象

- Service 分配了 External IP，但 `arping` 无回复
- Speaker metrics 中无 `metallb_speaker_announced` 指标
- Speaker 日志（info 级别）无任何服务相关输出

### 根因

所有节点打了 `node.kubernetes.io/exclude-from-external-load-balancers` 标签，Speaker 跳过全部节点。

Debug 日志关键行：
```
layer2_controller.go:235 "reason":"speaker's node has labeled 'node.kubernetes.io/exclude-from-external-load-balancers'"
layer2_controller.go:100 "reason":"no available nodes"
```

### 修复

```bash
kubectl label nodes xs4772 xs4773 xs4774 node.kubernetes.io/exclude-from-external-load-balancers-
```

### 调试命令速查

```bash
# 查宣告状态（最可靠）
curl -s <node-ip>:7472/metrics | grep metallb_speaker_announced

# 查宣告日志
kubectl logs -n metallb-system -l component=speaker | grep "serviceAnnounced"

# 查拒绝原因（需 debug 日志级别）
kubectl logs -n metallb-system -l component=speaker | grep -i "shouldannounce\|skipping should announce\|no available nodes\|exclude-from-external\|failed no active"
```

### 注意事项

- Speaker 默认 log-level=info，`ShouldAnnounce` 拒绝原因是 debug 级别，需要临时改 `--log-level=debug` 才能看到
- Debug 模式下接口扫描日志非常多，会冲掉重要日志，定位后应改回 info

---

## 问题 2：EIP ARP 通但 ping 不通

### 现象

从非 owner 节点：
```
arping -I bond0 10.34.251.210  → 收到回复（正常）
ping 10.34.251.210              → Destination Port Unreachable（正常）
```

从 owner 节点：
```
arping -I bond0 10.34.251.210  → 无回复（正常）
curl 10.34.251.210:80           → 正常返回（走 IPVS）
```

### 原因

这是 MetalLB L2 模式的预期行为：

- **ARP 通**：Speaker 用户态程序代答 ARP 请求（仅回复外部请求，不回复本机）
- **ping 不通**：EIP 未绑定到任何接口，内核不认识该 IP。kube-proxy/IPVS 只转发 Service 定义的端口（TCP:80），ICMP 不在规则中
- **owner 节点 arping 不通**：Speaker 不处理本机发出的 ARP 请求
- **owner 节点 curl 通**：走 IPVS 的 DNAT 规则，不经过 ARP

### 结论

只有匹配 Service 端口的流量能通过 EIP 访问，ICMP（ping）不通是正常的。
