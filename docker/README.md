# ARM64 Azure Pipelines Agent Dockerfile

This Dockerfile builds an ARM64-compatible Azure Pipelines (DevOps) agent for Kubernetes.

## Building the Image

```bash
cd docker
docker build -t neichmann/buildagent:arm64 .
```

For pushing to Docker Hub:

```bash
docker push neichmann/buildagent:arm64
```

## What's Included

- **Base**: arm64v8/ubuntu:22.04
- **Dependencies**: curl, git, jq, docker.io, build essentials
- **Startup Script**: Automatic agent download and configuration at runtime
- **User**: Non-root `agentuser` for security

## Key Features

- **Runtime Configuration**: Agent is downloaded and configured at container startup (not build time)
- **Idempotent**: Safe to restart - won't re-download if already configured
- **Environment-based**: All configuration via environment variables
- **Auto-cleanup**: Automatic deregistration when container stops

## Environment Variables Required

When running, provide these environment variables:

- `AZP_URL`: Azure DevOps organization URL (e.g., https://dev.azure.com/yourorg) **[REQUIRED]**
- `AZP_TOKEN`: Personal Access Token with Agent Pools scope **[REQUIRED]**
- `AZP_POOL`: Agent pool name (default: "Default")
- `AZP_AGENT_NAME`: Unique agent name (default: container hostname)
- `AZP_WORK`: Working directory (default: "_work")

## Example Usage - Local Docker

```bash
docker run \
  -e AZP_URL=https://dev.azure.com/yourorg \
  -e AZP_TOKEN=your-pat-token \
  -e AZP_POOL=ImmersiveRoom-Jetson-Staging-Agents \
  -e AZP_AGENT_NAME=k8s-agent-1 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  neichmann/buildagent:arm64
```

## Example Usage - Kubernetes

See `../kubernetes/apps/home/buildagent/config/deployment.yaml` for the Kubernetes deployment configuration.

## How It Works

1. Container starts and runs `start.sh`
2. Script validates required environment variables
3. Downloads Azure Pipelines Agent for ARM64 (if not already present)
4. Configures agent with connection details
5. Runs the agent in interactive mode
6. On container stop, agent auto-deregisters from pool

## Files

- `Dockerfile` - Container image definition
- `start.sh` - Startup script for runtime configuration
- `.dockerignore` - Docker build exclusions

