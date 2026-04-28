# syntax=docker/dockerfile:1.7
# OpenGPU toolchain image — used by CI and (via .devcontainer) local dev.
#
# Layers:
#   1. base   : Ubuntu 24.04 + system deps
#   2. cad    : OSS CAD Suite (Yosys, Verilator, iverilog, nextpnr, ...)
#   3. verible: Verible formatter/linter (separate release)
#   4. py     : Python tooling (ruff, mypy, pyslang, cocotb, pytest)
#   5. final  : non-root `dev` user, sane defaults
#
# Versions are passed in via build args sourced from tools/versions.env.

ARG UBUNTU_VERSION=24.04
ARG PYTHON_VERSION=3.12

# ---------- 1. base ----------
FROM ubuntu:${UBUNTU_VERSION} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    TZ=Etc/UTC

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget xz-utils tar gzip bzip2 unzip \
        git make cmake ninja-build pkg-config build-essential \
        gcc g++ \
        python3 python3-pip python3-venv python3-dev \
        libgmp-dev libmpfr-dev libmpc-dev libreadline-dev libffi-dev \
        zlib1g-dev libssl-dev \
        sudo locales tini jq && \
    locale-gen C.UTF-8

# ---------- 2. cad : OSS CAD Suite ----------
FROM base AS cad

ARG OSS_CAD_SUITE_DATE
ARG OSS_CAD_SUITE_ARCH=linux-x64
ARG OSS_CAD_SUITE_SHA256=""

RUN test -n "${OSS_CAD_SUITE_DATE}" || (echo "OSS_CAD_SUITE_DATE build-arg required" >&2; exit 1)

ENV OSS_CAD_PREFIX=/opt/oss-cad-suite

RUN set -eu; \
    DATE_NODASH="$(echo "${OSS_CAD_SUITE_DATE}" | tr -d -)"; \
    URL="https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_DATE}/oss-cad-suite-${OSS_CAD_SUITE_ARCH}-${DATE_NODASH}.tgz"; \
    echo "Fetching ${URL}"; \
    curl -fsSL --retry 5 --retry-delay 5 -o /tmp/oss-cad.tgz "${URL}"; \
    if [ -n "${OSS_CAD_SUITE_SHA256}" ]; then \
        echo "${OSS_CAD_SUITE_SHA256}  /tmp/oss-cad.tgz" | sha256sum -c -; \
    else \
        echo "WARNING: OSS_CAD_SUITE_SHA256 not provided; skipping verification" >&2; \
    fi; \
    mkdir -p "${OSS_CAD_PREFIX}"; \
    tar -xzf /tmp/oss-cad.tgz -C /opt; \
    rm /tmp/oss-cad.tgz

# ---------- 3. verible ----------
FROM cad AS verible

ARG VERIBLE_VERSION

RUN test -n "${VERIBLE_VERSION}" || (echo "VERIBLE_VERSION build-arg required" >&2; exit 1)

RUN set -eu; \
    URL="https://github.com/chipsalliance/verible/releases/download/${VERIBLE_VERSION}/verible-${VERIBLE_VERSION}-linux-static-x86_64.tar.gz"; \
    echo "Fetching ${URL}"; \
    curl -fsSL --retry 5 --retry-delay 5 -o /tmp/verible.tgz "${URL}"; \
    mkdir -p /opt/verible; \
    tar -xzf /tmp/verible.tgz -C /opt/verible --strip-components=1; \
    rm /tmp/verible.tgz; \
    ls /opt/verible/bin

# ---------- 3b. sv2v ----------
FROM verible AS sv2v

ARG SV2V_VERSION

RUN test -n "${SV2V_VERSION}" || (echo "SV2V_VERSION build-arg required" >&2; exit 1)

RUN set -eu; \
    URL="https://github.com/zachjs/sv2v/releases/download/${SV2V_VERSION}/sv2v-Linux.zip"; \
    echo "Fetching ${URL}"; \
    curl -fsSL --retry 5 --retry-delay 5 -o /tmp/sv2v.zip "${URL}"; \
    unzip -q /tmp/sv2v.zip -d /tmp/sv2v-extract; \
    install -Dm0755 /tmp/sv2v-extract/sv2v-Linux/sv2v /usr/local/bin/sv2v; \
    rm -rf /tmp/sv2v.zip /tmp/sv2v-extract; \
    sv2v --version

# ---------- 4. py : Python tooling ----------
FROM sv2v AS py

ARG PYTHON_VERSION

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    VIRTUAL_ENV=/opt/venv

RUN python3 -m venv "${VIRTUAL_ENV}"
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Pinned pip baseline; project extras installed in CI from pyproject.toml.
RUN pip install --upgrade 'pip>=24.0' 'setuptools>=70' 'wheel>=0.43'

# Tools used by CI workflows. Versions kept in sync with pyproject.toml
# extras (`[dev]`); duplicated here so the image is usable standalone.
RUN pip install \
        'ruff>=0.6,<1.0' \
        'mypy>=1.10,<2.0' \
        'pyslang>=10.0,<11' \
        'pytest>=8.0,<9' \
        'pytest-cov>=5.0,<6' \
        'cocotb>=2.0,<3' \
        'cocotb-test>=0.2,<1' \
        'pre-commit>=3.7,<5'

# ---------- 5. final ----------
FROM py AS final

ENV OSS_CAD_PREFIX=/opt/oss-cad-suite \
    PATH="/opt/oss-cad-suite/bin:/opt/oss-cad-suite/py3bin:/opt/verible/bin:/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Non-root user `dev` with passwordless sudo (dev convenience only;
# CI overrides USER as needed).
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Ubuntu 24.04 ships a default `ubuntu` user at UID/GID 1000; remove it
# so we can claim that range for our `dev` user.
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi && \
    if getent group ubuntu >/dev/null; then groupdel ubuntu 2>/dev/null || true; fi && \
    groupadd --gid ${USER_GID} ${USERNAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

WORKDIR /workspace
USER ${USERNAME}

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "-l"]

# Image labels for GHCR / OCI.
LABEL org.opencontainers.image.title="opengpu-toolchain" \
      org.opencontainers.image.description="Reproducible OSS toolchain for OpenSource-GPU-Architecture (Yosys, Verilator, iverilog, nextpnr, Verible, pyslang, cocotb)." \
      org.opencontainers.image.source="https://github.com/piyushptiwari1/OpenSource-GPU-Architecture" \
      org.opencontainers.image.licenses="MIT"
