# =============================================================================
# NeuroSphere Medical Robotics — Custom Jenkins Agent
# =============================================================================
# This image provides a fully-equipped CI/CD agent for the NeuroSphere
# pipeline. Every tool referenced in Jenkinsfile and Jenkinsfile.deploy is
# pre-installed so pipeline stages never need to download tooling at runtime.
#
# Compliance note: Pinning tool versions is recommended for FDA/IEC 62443
# reproducible-build requirements. Update versions deliberately and re-qualify.
# =============================================================================

FROM jenkins/inbound-agent:latest

LABEL maintainer="NeuroSphere DevOps <devops@neurosphere.med>"
LABEL description="Jenkins agent for NeuroSphere Medical Robotics CI/CD"
LABEL com.neurosphere.compliance="FDA-21CFR11"

# Switch to root for package installation
USER root

# ---- Environment variables --------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive \
    TERRAFORM_VERSION=1.7.5 \
    KUBECTL_VERSION=1.28.6 \
    KUSTOMIZE_VERSION=5.3.0 \
    KUBECONFORM_VERSION=0.6.4 \
    HELM_VERSION=3.14.2 \
    TRIVY_VERSION=0.50.1

# ---- System dependencies ----------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        unzip \
        jq \
        bc \
        git \
        make \
        wget \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ---- Docker CLI (no daemon — uses host socket or DinD) ----------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# ---- kubectl ----------------------------------------------------------------
RUN curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# ---- kustomize --------------------------------------------------------------
RUN curl -fsSL \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin/ \
    && chmod +x /usr/local/bin/kustomize

# ---- kubeconform (K8s manifest validation) ----------------------------------
RUN curl -fsSL \
        "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
        | tar -xz -C /usr/local/bin/ \
    && chmod +x /usr/local/bin/kubeconform

# ---- Terraform --------------------------------------------------------------
RUN curl -fsSL \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && terraform version

# ---- Helm -------------------------------------------------------------------
RUN curl -fsSL \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
        | tar -xz -C /tmp/ \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64 \
    && helm version

# ---- AWS CLI v2 -------------------------------------------------------------
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp/ \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && aws --version

# ---- Trivy (container / filesystem vulnerability scanner) -------------------
RUN curl -fsSL \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        | tar -xz -C /usr/local/bin/ trivy \
    && chmod +x /usr/local/bin/trivy \
    && trivy --version

# ---- Node.js 20 LTS + npm --------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ---- Node.js global tools ---------------------------------------------------
RUN npm install -g \
        eslint@latest \
        jest-junit@latest \
    && eslint --version

# ---- Python tools (lint, test, SAST, coverage) -----------------------------
RUN pip3 install --no-cache-dir --break-system-packages \
        flake8 \
        pytest \
        pytest-cov \
        bandit \
        coverage \
        safety \
    && flake8 --version \
    && pytest --version \
    && bandit --version

# ---- OWASP Dependency Check ------------------------------------------------
RUN DEPCHECK_VERSION=9.0.9 \
    && curl -fsSL \
        "https://github.com/jeremylong/DependencyCheck/releases/download/v${DEPCHECK_VERSION}/dependency-check-${DEPCHECK_VERSION}-release.zip" \
        -o /tmp/dependency-check.zip \
    && unzip -q /tmp/dependency-check.zip -d /opt/ \
    && ln -s /opt/dependency-check/bin/dependency-check.sh /usr/local/bin/dependency-check \
    && rm /tmp/dependency-check.zip

# ---- Add jenkins user to docker group (for socket access) -------------------
RUN groupadd -f docker \
    && usermod -aG docker jenkins

# ---- Create workspace and reports directories -------------------------------
RUN mkdir -p /home/jenkins/agent/workspace /home/jenkins/reports \
    && chown -R jenkins:jenkins /home/jenkins

# ---- Switch back to non-root jenkins user -----------------------------------
USER jenkins

WORKDIR /home/jenkins/agent

# ---- Healthcheck (validates agent tools are available) ----------------------
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD kubectl version --client && docker --version && terraform version
