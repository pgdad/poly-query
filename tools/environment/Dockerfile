# Reproducible Linux build/conformance environment for PolyQuery (x86-64).
# Not used for benchmarks (see ADR-0015).
FROM ubuntu:24.04
# Pinned to the build used on the experiment host (27+35); jdk.java.net has no "latest" path.
ARG JDK_URL=https://download.java.net/java/GA/jdk27/55ce5470a6294008af0057ff4626d0e5/35/GPL/openjdk-27_linux-x64_bin.tar.gz
ARG JDK_SHA256=95fc37eb3a18a27a26d5904c2d89d52bace8dafa9a078ca27f4747fbc4bf070b
ARG SBCL_VERSION=2.6.9
ARG GO_VERSION=1.27.1
ARG RUST_VERSION=1.96.0
ENV DEBIAN_FRONTEND=noninteractive PATH=/opt/sbcl/bin:/usr/local/go/bin:/root/.cargo/bin:/root/.local/bin:/usr/lib/jvm/jdk-27/bin:$PATH \
    JAVA_HOME=/usr/lib/jvm/jdk-27
RUN apt-get update && apt-get install -y --no-install-recommends build-essential nasm curl ca-certificates git bzip2 \
      python3 gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static rlwrap make && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /usr/lib/jvm/jdk-27 && curl -fsSL -o /tmp/jdk.tar.gz "$JDK_URL" \
 && echo "$JDK_SHA256  /tmp/jdk.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/jdk.tar.gz --strip-components=1 -C /usr/lib/jvm/jdk-27 && rm /tmp/jdk.tar.gz
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -xz -C /usr/local
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION} && cargo install just
RUN curl -fsSL -o /tmp/sbcl.tar.bz2 https://downloads.sourceforge.net/project/sbcl/sbcl/${SBCL_VERSION}/sbcl-${SBCL_VERSION}-x86-64-linux-binary.tar.bz2 \
 && tar -xjf /tmp/sbcl.tar.bz2 -C /tmp && cd /tmp/sbcl-${SBCL_VERSION}-x86-64-linux && INSTALL_ROOT=/opt/sbcl sh install.sh && rm -rf /tmp/sbcl*
RUN curl -fsSL https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh | bash \
 && clojure -M -e '(println (clojure-version))'
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && /root/.local/bin/uv python install 3.14 \
 && ln -s "$(/root/.local/bin/uv python find 3.14)" /usr/local/bin/python3.14
# As on the experiment host, python3 is 3.14 (the toolchain the engines target, e.g. csv.QUOTE_NOTNULL
# reading empty fields as None needs >= 3.13), not Ubuntu's 3.12.
RUN ln -s /usr/local/bin/python3.14 /usr/local/bin/python3
# The repository is bind-mounted with the host runner's uid; Go embeds VCS info and needs git to accept it.
RUN git config --system --add safe.directory '*'
WORKDIR /work
