# Proposal: Run the Immersive Room Applications MCP Server in the Kubernetes Cluster

Status: Implemented in templates (not yet deployed). Pending: applications image build and tag, and review of the public hostname.

## Goal

Deploy the Immersive Room applications MCP server (`mcp_servers/applications_server.py`) into the `home` namespace of the Talos cluster, next to the broker and management server. The management server then reaches it inside the cluster instead of through Azure Container Apps.

## Current State

| Item | Current value | Source |
| --- | --- | --- |
| Entry point | `python -m mcp_servers.applications_server` | `docker/Dockerfile.applications` |
| Port | 8006 (`PORT`) | `docker/Dockerfile.applications`, `applications_server.py` |
| Broker URL | `BROKER_URL`, default `ws://broker:8765` | `mcp_servers/broker_client.py` |
| Broker token | `MCP_TOKEN` (the broker principal `mcp-applications`) | `mcp_servers/broker_client.py` |
| Inbound auth | `APPLICATIONS_MCP_API_TOKEN` bearer token, 503 if unset, 401 if wrong | `applications_server.py` |
| Transport security | `MCP_ALLOWED_HOSTS`, `MCP_ALLOWED_ORIGINS` | `applications_server.py` |
| Health endpoint | None (the SSE endpoint returns 401 without a bearer token) | `applications_server.py` |
| Image build | `Docker@2 buildAndPush`, no `--platform` flag | `azure-pipelines-broker-staging.yml` |
| Azure deployment | Container App `ca-immersive-apps-staging` | `docs/operations/APPLICATIONS_MCP_AZURE_STAGING.md` |

The applications server has no Azure dependency. It only needs the broker, so no storage decision is required (unlike the management server in proposal 002).

## Proposed Kubernetes Layout

Follow the same pattern as the management server under `templates/config/kubernetes/apps/home/`:

- `applications/config/deployment.yaml.j2`: one replica, `Recreate` strategy, `nodeSelector` `kubernetes.io/arch: arm64`, `acr-pull` imagePullSecret, port 8006, TCP probes (see below).
- `applications/config/service.yaml.j2`: ClusterIP `applications` on port 8006.
- `applications/config/http-routes.yaml.j2`: host `applications-mcp.#{ cloudflare_domain }#` through `envoy-external`.
- `applications/config/secret-generator.yaml.j2` and `applications/config/applications-secrets.sops.yaml` (SOPS, age-encrypted).
- Argo CD application at `templates/config/kubernetes/argo/apps/home/applications.yaml.j2`, sync-wave `2`.
- Image tag in `bootstrap-apps.yaml` under `bootstrap_apps.applications.image`.

### Environment Variables

| Variable | Value | Source |
| --- | --- | --- |
| `PORT` | `8006` | deployment |
| `BROKER_URL` | `ws://broker.home.svc.cluster.local:8765` | deployment |
| `MCP_TOKEN` | broker token of the `mcp-applications` principal | secret `applications-secrets` |
| `APPLICATIONS_MCP_API_TOKEN` | new random token, at least 32 characters | secret `applications-secrets` |
| `MCP_ALLOWED_HOSTS` | `applications-mcp.#{ cloudflare_domain }#` | deployment |
| `MCP_ALLOWED_ORIGINS` | `https://web-dashboard.#{ cloudflare_domain }#` | deployment |

### Probes

The SSE endpoint returns 401 without a bearer token and streams with one, so an HTTP probe cannot check it cleanly. The deployment uses TCP socket probes on the `http` port instead. A future `/healthz` route would allow HTTP probes.

## Broker Integration

No broker change is needed. The cluster broker token table already contains the `mcp-applications` principal (`role: mcp`), with the same id as the Azure staging principal. Its token value is copied into the `applications-secrets` secret as `MCP_TOKEN`.

The `APPLICATIONS_MCP_API_TOKEN` is a new value. It is generated locally and is not shared with the Azure deployment.

## Management Server Change

The management server finds the applications MCP through `APPLICATIONS_MCP_URL` (`mcp_servers/management_server.py`). The cluster management deployment sets:

- `APPLICATIONS_MCP_URL=http://applications.home.svc.cluster.local:8006/sse`

This replaces the placeholder that proposal 002 kept out of scope. The management server calls the applications server inside the cluster, so it does not need the public hostname.

The `list_registered_mcp_servers` tool in `management_server.py` now reads each MCP URL from an environment variable (`AV_MCP_URL`, `AUDIO_MCP_URL`, `DISPLAY_MCP_URL`, `VESTABOARD_MCP_URL`, `MANAGEMENT_MCP_URL`, `APPLICATIONS_MCP_URL`). The localhost defaults stay for local runs. The cluster sets these only when the matching MCP server is deployed.

## Image Build

The staging pipeline's `BuildPushApplicationsMcp` job is changed to a `docker buildx` multi-arch build (`linux/amd64,linux/arm64`) from `docker/Dockerfile.applications`. It uses the same pattern as the broker and management jobs. The cluster pulls the arm64 manifest.

## Decisions

1. Scope: applications MCP server only in this proposal. The other MCP servers are inventoried below and need their own decisions before deployment.
2. Public hostname: `applications-mcp.#{ cloudflare_domain }#` (`applications-mcp.gitlab.be`). Confirmed by the user.
3. Probes: TCP socket, not HTTP, because the SSE endpoint requires a bearer token.
4. The Dockerfile default `MCP_TOKEN=mcp-applications-supersecret` is a placeholder. The cluster always sets `MCP_TOKEN` from the secret, so the placeholder must not be used there.

## Other MCP Servers (Inventory)

| MCP | Entry point | Port | Broker principal | Inbound secret | Other inputs | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| av | `mcp_servers.av_server` (`Dockerfile.av_server`) | 8000 | `mcp-light` | `AV_MCP_API_TOKEN` | `MCP_ALLOWED_HOSTS`, `MCP_ALLOWED_ORIGINS` | Dockerfile uses a `light` token; `light_server.py` is a second file that also names itself `av` |
| audio | `mcp_servers.audio_server` | 8001 | `mcp-audio` | none | none | No secret beyond broker token |
| display | `mcp_servers.display_server` | 8002 | `mcp-display` | none | none | No secret beyond broker token |
| vestaboard | `mcp_servers.vestaboard_server` | 8003 | `mcp-vestaboard` | `VESTABOARD_MCP_API_TOKEN` | `MCP_ALLOWED_HOSTS`, `MCP_ALLOWED_ORIGINS` | Hardware or Vestaboard API reach from cluster to confirm |
| image-services | `mcp_servers.image_services_server` | 8007 | none (no broker) | `IMAGE_SERVICES_MCP_API_TOKEN` | `IMAGE_SERVICES_MCP_ALLOWED_HOSTS/ORIGINS`, `KIOSK_WELCOME_*` keys, Azure storage (`AZURE_STORAGE_*`) | Needs Azure storage access and OpenAI or Foundry keys |
| room-mailbox | `mcp_servers.room_mailbox_server` | 8008 | none (no broker) | `ROOMMAILBOX_MCP_API_KEYS` (JSON) | `ROOMMAILBOX_MCP_ALLOWED_HOSTS/ORIGINS` | Graph credentials come per request in headers, not from server env |
| management | `mcp_servers.management_server` | 8004 | `mcp-management` | `MANAGEMENT_API_TOKEN` | `PRESENCE_SOURCE_PRINCIPALS_JSON` | Already in cluster (proposal 002) |

Decisions (confirmed):

- Public exposure: every MCP gets a `<name>-mcp.#{ cloudflare_domain }#` route through `envoy-external`.
- Image-services and room-mailbox stay broker-free. They get no broker principal and no `MCP_TOKEN`.
- Every image is built as arm64. The staging pipeline's av, vestaboard, image-services, and room-mailbox jobs now use the buildx multi-arch pattern (`linux/amd64,linux/arm64`, pushed to ACR).

Open for the arm64 build:

- Audio and display are not built by the staging pipeline. `azure-pipelines.yml` builds them with `command: build` and no push, so they need a staging buildx job with their own ACR repositories.
- Clients using the Azure bearer tokens (AV, Vestaboard, image services, room mailbox) must be updated if new tokens are generated for the cluster.

## Remaining Actions

- Run the staging pipeline (`BuildPushApplicationsMcp`) and record the build number.
- Set `bootstrap_apps.applications.image` in `bootstrap-apps.yaml` to the built tag (currently `REPLACE_WITH_BUILD_TAG`).
- Confirm the public hostname `applications-mcp.gitlab.be` and that the Cloudflare tunnel covers it.
- Confirm that desktop and Jetson clients can reach the cluster broker at `broker.gitlab.be` (see proposal 001).
- Run `task configure -y` and check the diff, then restore unrelated re-encrypted SOPS files.
- Deploy, then run the smoke test from `docs/operations/APPLICATIONS_MCP_AZURE_STAGING.md` against the cluster hostname.

## Out of Scope

- Removing the Azure Container App `ca-immersive-apps-staging`.
- Changing the applications server code or its tool contract.
- Moving the other MCP servers into the cluster.
