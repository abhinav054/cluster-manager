FROM gcr.io/kaniko-project/executor:latest as builder


FROM amazon/aws-cli:latest

# setup kaniko

RUN mkdir /kaniko

COPY --from=builder /kaniko/ssl/certs/ /kaniko/ssl/certs/
COPY --from=builder /etc/nsswitch.conf /etc/nsswitch.conf

ENV USER root
ENV PATH $PATH:/kaniko
ENV SSL_CERT_DIR=/kaniko/ssl/certs

COPY --from=builder --chown=0:0 /kaniko/docker-credential-gcr /kaniko/docker-credential-gcr
COPY --from=builder --chown=0:0 /kaniko/docker-credential-ecr-login /kaniko/docker-credential-ecr-login
COPY --from=builder --chown=0.0 /kaniko/docker-credential-acr-env /kaniko/docker-credential-acr-env
COPY --from=builder /kaniko/.docker /kaniko/.docker
ENV DOCKER_CONFIG /kaniko/.docker/
ENV DOCKER_CREDENTIAL_GCR_CONFIG /kaniko/.config/gcloud/docker_credential_gcr_config.json

RUN /kaniko/docker-credential-gcr /kaniko/docker-credential-gcr 

COPY --from=builder /kaniko/executor /kaniko/executor

COPY eksctl /usr/local/bin/eksctl

COPY yq /usr/local/bin/yq

RUN dnf install openssh

RUN dnf install git

RUN mkdir /app

COPY helm /usr/local/bin/helm

COPY cluster-manager.sh /app/cluster-manager.sh

ENTRYPOINT [""]

