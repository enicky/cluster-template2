FROM arm64v8/ubuntu:22.04

# Install required dependencies and download agent in one layer to avoid duplication
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    libunwind8 \
    libicu70 \
    libssl3 \
    zlib1g \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash agentuser && \
    mkdir -p /home/agentuser/agent && \
    chown -R agentuser:agentuser /home/agentuser/agent && \
    cd /home/agentuser/agent && \
    curl -L https://download.agent.dev.azure.com/agent/5.279.0/vsts-agent-linux-arm64-5.279.0.tar.gz | tar xz && \
    chown -R agentuser:agentuser /home/agentuser/agent && \
    chmod -R u+w /home/agentuser/agent && \
    if [ -f /home/agentuser/agent/bin/installdependencies.sh ]; then \
      /home/agentuser/agent/bin/installdependencies.sh || true; \
    fi && \
    chown -R agentuser:agentuser /home/agentuser/agent && \
    chmod -R u+w /home/agentuser/agent && \
    rm -rf /var/lib/apt/lists/*

# Copy startup script
COPY --chown=agentuser:agentuser start.sh /home/agentuser/start.sh
RUN chmod +x /home/agentuser/start.sh

# Run as agentuser
USER agentuser
WORKDIR /home/agentuser/agent

# Startup script handles agent configuration and running
ENTRYPOINT ["/home/agentuser/start.sh"]
