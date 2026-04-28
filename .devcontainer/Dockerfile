# Dev container — thin layer over the published toolchain image.
# Override TOOLCHAIN_IMAGE to use a local build (e.g. `opengpu-toolchain:dev`).
ARG TOOLCHAIN_IMAGE=ghcr.io/piyushptiwari1/opengpu-toolchain:latest
FROM ${TOOLCHAIN_IMAGE}

# Reasonable shell defaults for interactive use.
USER root
RUN echo 'export HISTFILE=/home/dev/.bash_history_dir/.bash_history' \
        >> /etc/bash.bashrc && \
    mkdir -p /home/dev/.bash_history_dir && \
    chown -R dev:dev /home/dev/.bash_history_dir

USER dev
