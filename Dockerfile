# BUILDER PHASE
FROM --platform=${BUILDPLATFORM} docker.io/golang:1.23.0 AS builder
WORKDIR /workspace

# Install dependencies.
RUN apt-get update && apt-get install -y jq && mkdir bin

# Run this with docker build --build-arg goproxy=$(go env GOPROXY) to override the goproxy
ARG goproxy=https://proxy.golang.org
ENV GOPROXY=$goproxy

# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
USER 0

# Cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Copy the sources
COPY ./ ./

ARG TARGETOS
ARG TARGETARCH

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    make build OS=${TARGETOS} ARCH=${TARGETARCH}

# CNI DOWNLOAD PHASE
FROM alpine AS cni
ARG GOARCH=amd64
ARG CNI_PLUGINS_VERSION=v1.6.0
RUN apk add --no-cache curl && \
    curl -Lo cni.tar.gz https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-$GOARCH-$CNI_PLUGINS_VERSION.tgz && \
    tar -xf cni.tar.gz

# FINAL IMAGE
FROM alpine
ARG GOARCH
ARG ALPINE_VERSION=v3.20
LABEL maintainer="Cast AI"
RUN echo -e "https://alpine.global.ssl.fastly.net/alpine/$ALPINE_VERSION/main\nhttps://alpine.global.ssl.fastly.net/alpine/$ALPINE_VERSION/community" > /etc/apk/repositories && \
    apk add --no-cache ipset iptables ip6tables graphviz font-noto

COPY --from=cni bridge host-local loopback portmap /opt/cni/bin/
ADD https://raw.githubusercontent.com/kubernetes-sigs/iptables-wrappers/e139a115350974aac8a82ec4b815d2845f86997e/iptables-wrapper-installer.sh /
RUN chmod 700 /iptables-wrapper-installer.sh && /iptables-wrapper-installer.sh --no-sanity-check

COPY --from=builder workspace/bin/* /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/kg"]
