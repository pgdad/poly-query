#!/usr/bin/env bash
# Installs the PolyQuery engine toolchains on the ARM host (spark, aarch64), pinned to the
# x86 host's versions (tools/environment/versions.json). Run on the ARM host as a sudoer.
set -euo pipefail
P=/opt/pq
sudo mkdir -p $P /opt/pq-src
sudo chown "$USER" /opt/pq-src
cd /opt/pq-src
# JDK 27+35 (Oracle OpenJDK build, same as host)
if [[ ! -x $P/jdk-27/bin/javac ]]; then
  u=https://download.java.net/java/GA/jdk27/55ce5470a6294008af0057ff4626d0e5/35/GPL/openjdk-27_linux-aarch64_bin.tar.gz
  curl -fsSLo jdk.tgz $u; echo "$(curl -fsSL $u.sha256)  jdk.tgz" | sha256sum -c -
  sudo tar -C $P -xzf jdk.tgz
fi
# Go 1.27.1
if [[ ! -x $P/go/bin/go ]]; then
  curl -fsSLo go.tgz https://go.dev/dl/go1.27.1.linux-arm64.tar.gz
  sudo tar -C $P -xzf go.tgz
fi
# Rust 1.96.0 with clippy + rustfmt
if [[ ! -x $P/rust/cargo/bin/cargo ]]; then
  curl -fsSLo rustup-init https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init
  chmod +x rustup-init
  sudo env RUSTUP_HOME=$P/rust/rustup CARGO_HOME=$P/rust/cargo ./rustup-init -y --no-modify-path \
    --profile minimal --default-toolchain 1.96.0 -c clippy -c rustfmt
fi
# Python 3.14.0 (uv standalone build, same as host)
if [[ ! -d $P/python ]]; then
  curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/opt/pq-src/uv UV_NO_MODIFY_PATH=1 sh
  sudo env UV_PYTHON_INSTALL_DIR=$P/python /opt/pq-src/uv/uv python install 3.14.0
fi
# Clojure CLI 1.12.3.1577
if [[ ! -x /usr/local/bin/clojure ]]; then
  curl -fsSLo clj-install.sh https://github.com/clojure/brew-install/releases/download/1.12.3.1577/linux-install.sh
  chmod +x clj-install.sh; sudo ./clj-install.sh
fi
# SBCL 2.6.9 from source (no arm64 binary release), bootstrapped by the distro sbcl
if [[ ! -x $P/sbcl/bin/sbcl ]]; then
  command -v sbcl >/dev/null || sudo apt-get install -y -q sbcl
  curl -fsSLo sbcl.tar.bz2 https://downloads.sourceforge.net/project/sbcl/sbcl/2.6.9/sbcl-2.6.9-source.tar.bz2
  tar xjf sbcl.tar.bz2; cd sbcl-2.6.9
  sh make.sh --prefix=$P/sbcl --fancy > ../sbcl-build.log 2>&1
  # shellcheck disable=SC2024  # the log is user-owned on purpose
  sudo sh install.sh >> ../sbcl-build.log 2>&1
  cd ..
fi
sudo chmod -R a+rX $P
echo "--- versions"
$P/jdk-27/bin/java -version 2>&1 | head -n1
$P/go/bin/go version
$P/rust/cargo/bin/rustc --version 2>/dev/null || sudo env RUSTUP_HOME=$P/rust/rustup $P/rust/cargo/bin/rustc --version
ls $P/python
/usr/local/bin/clojure --version 2>/dev/null || PATH=$P/jdk-27/bin:$PATH clojure --version
$P/sbcl/bin/sbcl --version
echo "done"
