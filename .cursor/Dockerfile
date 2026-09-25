# Cloud Agent base image for building/testing GrokIslandCore on Linux.
#
# The macOS app (SwiftUI + AppKit + Xcode) cannot build on Linux, but the
# GrokIslandCore Swift package and its XCTest suite can. The official Swift
# image ships the full Swift + clang/libstdc++ toolchain, so the OpenCombine
# C++ helper (used as the Linux replacement for Apple's Combine) compiles
# without extra system packages.
FROM swift:6.0.3-noble

# Tools the Cloud Agent and git workflows expect.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git curl ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/*

# Provide a passwordless-sudo `ubuntu` user to match Cloud Agent conventions.
RUN if ! id -u ubuntu >/dev/null 2>&1; then useradd -m -s /bin/bash ubuntu; fi \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu
