#--- dockerfile to test hugot  ---

ARG GO_VERSION=1.24.4
ARG ONNXRUNTIME_VERSION=1.22.0
ARG BUILD_PLATFORM=linux/arm64

#--- runtime layer with all hugot dependencies for cpu ---

FROM --platform=$BUILD_PLATFORM public.ecr.aws/amazonlinux/amazonlinux:2023 AS hugot-runtime
ARG GO_VERSION
ARG ONNXRUNTIME_VERSION

ENV PATH="$PATH:/usr/local/go/bin" \
    GOPJRT_NOSUDO=1

COPY ./scripts/download-onnxruntime.sh /download-onnxruntime.sh
RUN --mount=src=./go.mod,dst=/go.mod \
    dnf --allowerasing -y install gcc jq bash tar xz gzip glibc-static libstdc++ wget zip git dirmngr sudo which && \
    ln -s /usr/lib64/libstdc++.so.6 /usr/lib64/libstdc++.so && \
    dnf clean all && \
    # tokenizers
    tokenizer_version=1.20.2 && \
    echo "tokenizer_version: $tokenizer_version" && \
    curl -LO https://github.com/daulet/tokenizers/releases/download/v1.20.2/libtokenizers.linux-arm64.tar.gz && \
    tar -C /usr/lib -xzf libtokenizers.linux-arm64.tar.gz && \
    rm libtokenizers.linux-arm64.tar.gz && \
    # onnxruntime cpu
    sed -i 's/\r//g' /download-onnxruntime.sh && chmod +x /download-onnxruntime.sh && \
    /download-onnxruntime.sh ${ONNXRUNTIME_VERSION} && \
    # XLA/goMLX
    curl -sSf https://raw.githubusercontent.com/gomlx/gopjrt/main/cmd/install_linux_arm64_amazonlinux.sh | bash && \
    # go
    curl -LO https://golang.org/dl/go${GO_VERSION}.linux-arm64.tar.gz && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-arm64.tar.gz && \
    rm go${GO_VERSION}.linux-arm64.tar.gz && \
    # NON-PRIVILEGED USER
    # create non-privileged testuser with id: 1000
    useradd -u 1000 -m testuser && usermod -a -G wheel testuser && \
    echo "testuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/testuser

#--- test layer ---

FROM --platform=$BUILD_PLATFORM hugot-runtime AS hugot-build

COPY . /build

RUN cd /build && \
    chown -R testuser:testuser /build && \
    git clone https://github.com/gomlx/gopjrt /gopjrt && \
    # cli binary
    cd /build/cmd && CGO_ENABLED=1 CGO_LDFLAGS="-L/usr/lib/" GOOS=linux GOARCH=arm64 CGO_CFLAGS="-I/gopjrt/c" go build -tags "ALL" -a -o /cli main.go && \
    cd / && \
    curl -LO https://github.com/gotestyourself/gotestsum/releases/download/v1.12.0/gotestsum_1.12.0_linux_arm64.tar.gz && \
    tar -xzf gotestsum_1.12.0_linux_arm64.tar.gz --directory /usr/local/bin && \
    # entrypoint
    cp /build/scripts/entrypoint.sh /entrypoint.sh && sed -i 's/\r//g' /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

#--- artifacts layer ---
FROM --platform=$BUILD_PLATFORM scratch AS artifacts

COPY --from=hugot-build /usr/lib64/onnxruntime.so onnxruntime-linux-arm64.so
COPY --from=hugot-build /usr/lib/libtokenizers.a libtokenizers.a
COPY --from=hugot-build /cli /hugot-cli-linux-arm64
