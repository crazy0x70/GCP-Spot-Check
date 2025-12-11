# 基于 Debian slim 版的 Google Cloud SDK 镜像，避免 Alpine 上 gcloud 兼容性问题
FROM google/cloud-sdk:slim

ENV DEBIAN_FRONTEND=noninteractive \
    CLOUDSDK_CORE_DISABLE_PROMPTS=1

# 仅补齐 jq 依赖，其余 gcloud 组件由基础镜像提供
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# 将脚本放入 PATH，并保留原生文件名方便与文档保持一致
COPY gcp-spot-check.sh /usr/local/bin/gcpsc
RUN chmod +x /usr/local/bin/gcpsc

# 配置与密钥默认存放位置，可通过 -v 映射覆盖
VOLUME ["/etc/gcpsc", "/var/log"]

# 默认保持容器存活，便于 docker exec 进入交互/巡检；可通过 docker run ... "gcpsc check" 覆盖 CMD
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["tail -f /dev/null"]
