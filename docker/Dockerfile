FROM arm64v8/ubuntu:22.04

# Install required dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    libunwind8 \
    libicu70 \
    libssl3 \
    zlib1g \
    ca-certificates \
    docker.io \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create agent user and working directory
RUN useradd -m -s /bin/bash agentuser && \
    usermod -aG sudo agentuser && \
    mkdir -p /home/agentuser/agent && \
    chown -R agentuser:agentuser /home/agentuser/agent && \
    echo "agentuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /home/agentuser/agent

# Download and extract Azure Pipelines Agent for ARM64 (v5.279.0)
RUN curl -L https://download.agent.dev.azure.com/agent/5.279.0/vsts-agent-linux-arm64-5.279.0.tar.gz | tar xz

# Install agent dependencies
RUN if [ -f /home/agentuser/agent/bin/installdependencies.sh ]; then \
      /home/agentuser/agent/bin/installdependencies.sh || true; \
    fi

# Copy startup script
COPY --chown=agentuser:agentuser start.sh /home/agentuser/start.sh
RUN chmod +x /home/agentuser/start.sh

# Run as agentuser
USER agentuser

# Startup script handles agent configuration and running
ENTRYPOINT ["/home/agentuser/start.sh"]
