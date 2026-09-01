#!/bin/bash
set -e

echo "=== Azure Pipelines Agent Startup ==="
echo "Running as user: $(whoami) (UID: $(id -u))"
echo "Groups: $(id -G)"

# Check required environment variables
if [ -z "$AZP_URL" ]; then
  echo "ERROR: AZP_URL environment variable not set"
  exit 1
fi

if [ -z "$AZP_TOKEN" ]; then
  echo "ERROR: AZP_TOKEN environment variable not set"
  exit 1
fi

# Set defaults
AZP_POOL=${AZP_POOL:-Default}
AZP_AGENT_NAME=${AZP_AGENT_NAME:-$(hostname)}
AZP_WORK=${AZP_WORK:-_work}

echo "Configuration:"
echo "  URL: $AZP_URL"
echo "  Pool: $AZP_POOL"
echo "  Agent Name: $AZP_AGENT_NAME"
echo "  Work Directory: $AZP_WORK"

# Navigate to agent directory
cd /home/agentuser/agent

# Check if already configured
if [ ! -f /home/agentuser/agent/.agent ]; then
  echo "Configuring agent..."
  ./config.sh \
    --unattended \
    --url "$AZP_URL" \
    --auth pat \
    --token "$AZP_TOKEN" \
    --pool "$AZP_POOL" \
    --agent "$AZP_AGENT_NAME" \
    --work "$AZP_WORK" \
    --acceptTeeEula
fi

echo "Starting agent..."
exec ./run.sh
