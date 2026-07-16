FROM jenkins/jenkins:lts-jdk17

# GID of the host's docker socket — passed at build time so the jenkins user
# can talk to the mounted socket without running as root.
ARG DOCKER_GID=999
ARG KUBECTL_VERSION=v1.33.1
ARG TRIVY_VERSION=0.72.0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg lsb-release gettext-base jq \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl

# trivy — image vulnerability scanning in the pipeline
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /usr/local/bin trivy \
 && chmod +x /usr/local/bin/trivy

# Match the host docker group so the socket is usable as the jenkins user
RUN groupadd -g ${DOCKER_GID} hostdocker || groupmod -g ${DOCKER_GID} $(getent group ${DOCKER_GID} | cut -d: -f1) ; \
    usermod -aG ${DOCKER_GID} jenkins

USER jenkins

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Skip the setup wizard; configuration is code, not clicks.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.model.DownloadService.noSignatureCheck=true"
