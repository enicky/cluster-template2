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
    && rm -rf /var/lib/apt/lists/*

# Create agent user (will have UID 1000)
RUN useradd -m -s /bin/bash agentuser

# Download and extract agent as root into a seed dir (copied onto the persistent volume at startup)
WORKDIR /opt/agent-seed
RUN curl -L https://download.agent.dev.azure.com/agent/5.279.0/vsts-agent-linux-arm64-5.279.0.tar.gz | tar xz && \
    if [ -f /opt/agent-seed/bin/installdependencies.sh ]; then \
      /opt/agent-seed/bin/installdependencies.sh || true; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Fix ALL permissions - ensure agentuser owns everything and can write
RUN chown -R agentuser:agentuser /home/agentuser /opt/agent-seed && \
    chmod -R 777 /home/agentuser /opt/agent-seed

# Copy startup script and set permissions
COPY start.sh /home/agentuser/start.sh
RUN chown agentuser:agentuser /home/agentuser/start.sh && \
    chmod 755 /home/agentuser/start.sh

# Run as agentuser
USER agentuser
WORKDIR /home/agentuser/agent

# Startup script handles agent configuration and running
ENTRYPOINT ["/home/agentuser/start.sh"]
