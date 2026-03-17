FROM alpine:3.19

ARG TARGETARCH=amd64

RUN apk add --no-cache bash iptables jq curl && \
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm -f kubectl

# Script is mounted via ConfigMap at /snat-gateway/snat-gateway.sh
CMD ["bash"]
