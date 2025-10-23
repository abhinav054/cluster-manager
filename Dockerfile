FROM gcr.io/kaniko-project/executor:latest AS builder


FROM amazon/aws-cli:latest

# setup kaniko

RUN mkdir /kaniko

COPY --from=builder /kaniko/ssl/certs/ /kaniko/ssl/certs/
COPY --from=builder /etc/nsswitch.conf /etc/nsswitch.conf

ENV HOME /root

ENV USER root
ENV PATH $PATH:/kaniko
ENV SSL_CERT_DIR=/kaniko/ssl/certs

COPY --from=builder --chown=0:0 /kaniko/docker-credential-gcr /kaniko/docker-credential-gcr
COPY --from=builder --chown=0:0 /kaniko/docker-credential-ecr-login /kaniko/docker-credential-ecr-login
COPY --from=builder --chown=0.0 /kaniko/docker-credential-acr-env /kaniko/docker-credential-acr-env
COPY --from=builder /kaniko/.docker /kaniko/.docker
ENV DOCKER_CONFIG /kaniko/.docker/
ENV DOCKER_CREDENTIAL_GCR_CONFIG /kaniko/.config/gcloud/docker_credential_gcr_config.json

# RUN /kaniko/docker-credential-gcr /kaniko/docker-credential-gcr 

COPY --from=builder /kaniko/executor /kaniko/executor

RUN dnf install -y git

RUN curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

RUN dnf install -y openssl tar && \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

RUN curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" && tar -xzf eksctl_$(uname -s)_amd64.tar.gz -C /usr/local/bin && rm eksctl_$(uname -s)_amd64.tar.gz

RUN curl -LO "https://dl.k8s.io/release/v1.33.0/bin/$(uname -s | tr '[:upper:]' '[:lower:]')/amd64/kubectl" && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

RUN mkdir /app

COPY --chown=0:0 cluster-manager.sh /app/cluster-manager.sh

COPY --chown=0:0 install-git.sh /app/install-git.sh

COPY --chown=0:0 build-and-push.sh /app/build-and-push.sh

COPY --chown=0:0 modify-val.sh /app/modify-val.sh

COPY --chown=0:0 commit-env.sh /app/commit-env.sh

RUN mkdir /dockerfiles

COPY --chown=0:0 Dockerfile.javascript /dockerfiles/Dockerfile.javascript

COPY --chown=0:0 Dockerfile.python /dockerfiles/Dockerfile.python

ENTRYPOINT ["/app/cluster-manager.sh"]

