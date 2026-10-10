# Reproducible Linux build/conformance environment for PolyQuery (x86-64).
# Not used for benchmarks (see ADR-0015).
FROM ubuntu:24.04
ARG JDK_URL=https://download.java.net/java/GA/jdk27/latest/openjdk-27_linux-x64_bin.tar.gz
ARG SBCL_VERSION=2.6.9
ARG GO_VERSION=1.27.1
ARG RUST_VERSION=1.96.0
ENV DEBIAN_FRONTEND=noninteractive PATH=/opt/sbcl/bin:/usr/local/go/bin:/root/.cargo/bin:/root/.local/bin:/usr/lib/jvm/jdk-27/bin:$PATH \
    JAVA_HOME=/usr/lib/jvm/jdk-27
RUN apt-get update && apt-get install -y --no-install-recommends build-essential nasm curl ca-certificates git bzip2 \
      python3 gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static rlwrap make && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /usr/lib/jvm/jdk-27 && curl -fsSL "$JDK_URL" | tar -xz --strip-components=1 -C /usr/lib/jvm/jdk-27
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -xz -C /usr/local
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION} && cargo install just
RUN curl -fsSL -o /tmp/sbcl.tar.bz2 https://downloads.sourceforge.net/project/sbcl/sbcl/${SBCL_VERSION}/sbcl-${SBCL_VERSION}-x86-64-linux-binary.tar.bz2 \
 && tar -xjf /tmp/sbcl.tar.bz2 -C /tmp && cd /tmp/sbcl-${SBCL_VERSION}-x86-64-linux && INSTALL_ROOT=/opt/sbcl sh install.sh && rm -rf /tmp/sbcl*
RUN curl -fsSL https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh | bash \
 && clojure -M -e '(println (clojure-version))'
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && /root/.local/bin/uv python install 3.14 \
 && ln -s "$(/root/.local/bin/uv python find 3.14)" /usr/local/bin/python3.14
WORKDIR /work
