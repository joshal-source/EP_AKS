FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        python3 \
        tar \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY mgmt-proxy.py /mgmt-proxy.py
RUN chmod +x /entrypoint.sh /mgmt-proxy.py

WORKDIR /opt/splunk-edge

ENTRYPOINT ["/entrypoint.sh"]
