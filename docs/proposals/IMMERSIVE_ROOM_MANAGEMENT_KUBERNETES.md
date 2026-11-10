# Proposal: Run the Immersive Room Management Server in the Kubernetes Cluster

Status: Implemented (manifests rendered, not yet deployed). Pending: Azure service principal values, storage account name, management image build, and web-dashboard image rebuild.

## Goal

Deploy the Immersive Room management server (`mcp_servers/management_server.py`) into the `home` namespace of the Talos cluster, alongside the broker, so that in-cluster components can reach it without going through Azure Container Apps.

## Current State

| Item | Current value | Source |
| --- | --- | --- |
| Entry point | `python -m mcp_servers.management_server` | `docker/Dockerfile.management` |
| Port | 8004 (`PORT`) | `docker/Dockerfile.management` |
| Health endpoint | `/healthz` | `mcp_servers/management_server.py` |
| Broker URL default | `ws://broker:8765` (`BROKER_URL`) | `docker/Dockerfile.management` |
| Auth token | `MANAGEMENT_API_TOKEN`, falls back to `MCP_TOKEN` | `mcp_servers/management_server.py` |
| Image build | `Docker@2 buildAndPush`, no `--platform` flag | `azure-pipelines-broker-staging.yml` |
| Azure deployment | Container App `ca-immersive-mgmt-staging` / `-prod` | pipelines and `infra/staging/main.bicep` |

## Blockers Found in the Current Code

1. **Azure Storage is required.** Kiosk pages and assets, device inventory, device telemetry, offline recordings, and research data use `DefaultAzureCredential` with Blob and Table clients (`mcp_servers/storage_service.py`). Without `AZURE_STORAGE_ACCOUNT_NAME` the kiosk, device, and recording features return "not configured" errors.
2. **The image is not arm64.** The management image is built without a `--platform` flag. The cluster's workers are arm64, so the image must be built multi-arch like the broker.
3. **Other MCP servers are called.** The Azure deployment also runs AV, Vestaboard, applications, image services, and room-mailbox MCP servers, which the management server reaches through their own endpoints and tokens.

## Options for Storage (decision required)

| Option | Description | Pros | Cons |
| --- | --- | --- | --- |
| A. Keep Azure Storage | Pod authenticates to Azure with a service principal stored in a SOPS secret (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`). `DefaultAzureCredential` reads these environment variables. | No code change. Same data as Azure. | Cluster depends on Azure; a secret must be rotated. |
| B. Move to cluster storage | Replace Blob and Table access with Longhorn-backed files or a local database. | No Azure dependency. | Requires code changes in the storage modules and a data migration. |

Recommendation: Option A for the first deployment, with Option B as a later proposal.

## Proposed Kubernetes Layout

Follow the same pattern as the broker under `templates/config/kubernetes/apps/home/`:

- `management/config/deployment.yaml.j2`: one replica, `Recreate` strategy, `nodeSelector` `kubernetes.io/arch: arm64`, `acr-pull` imagePullSecret, port 8004, `/healthz` probes.
- `management/config/service.yaml.j2`: ClusterIP `management` on port 8004.
- `management/config/http-routes.yaml.j2`: host `management.#{ cloudflare_domain }#` through `envoy-external` (hostname to be confirmed).
- `management/config/pvcs.yaml.j2`: Longhorn PVC only if Option B is chosen or local cache files are needed.
- `management/config/secret-generator.yaml.j2` and a SOPS secret for tokens and Azure credentials.
- Argo CD application at `templates/config/kubernetes/argo/apps/home/management.yaml.j2`.

Environment variables (values come from secrets or the bootstrap file):

| Variable | Value |
| --- | --- |
| `PORT` | `8004` |
| `BROKER_URL` | `ws://broker.home.svc.cluster.local:8765` |
| `MANAGEMENT_API_TOKEN` | secret (`management-secrets`, generated) |
| `MCP_TOKEN` | secret (`management-secrets`, same value as the broker's `stg-mcp-management-*` principal) |
| `MCP_ALLOWED_HOSTS` | `management.gitlab.be` |
| `MCP_ALLOWED_ORIGINS` | `https://web-dashboard.gitlab.be` |
| `AZURE_STORAGE_ACCOUNT_NAME` | Azure storage account (Option A) |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` | secret (Option A) |

## Broker Integration

No broker change is needed. The broker token table already contains a `stg-mcp-management-*` principal, and its value is copied into the management `MCP_TOKEN`.

## Image Build

Add an arm64 (and amd64, if needed) build to the management pipeline using `docker buildx build --platform linux/amd64,linux/arm64 --push`, as already done for the broker. The cluster tag should be pinned to the build number after the first successful run.

## Decisions

1. Storage: Option A (Azure Storage with a service principal in a SOPS secret).
2. Scope: management server only. The other MCP servers come later.
3. Public hostname: `management.gitlab.be`.
4. Web-dashboard: the ARM64 (cluster) build's `VITE_MANAGEMENT_SSE_URL` and `VITE_MANAGEMENT_API_URL` point to `https://management.gitlab.be`. The Azure production values are unchanged.

## Remaining Actions

- Fill `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` in `management-secrets.sops.yaml`, and set the storage account name and blob/table URLs in `deployment.yaml.j2` (placeholders `REPLACE_ME_STORAGE_ACCOUNT_NAME`).
- Set `bootstrap_apps.management.image` in `bootstrap-apps.yaml` to the built `immersive-room/management-mcp` ARM64 tag.
- Set `PRESENCE_SOURCE_PRINCIPALS_JSON` (currently `{}`) to the staging device-to-principal mapping.
- Rebuild and push the web-dashboard image with a new tag, then update `bootstrap_apps.web_dashboard.image`.
- Confirm the management `MANAGEMENT_API_TOKEN` is entered in the dashboard login.
- Keep `APPLICATIONS_MCP_URL` out of scope (applications MCP not yet in the cluster).

## Out of Scope

- Changing the web-dashboard, Jetson, desktop, or other client URLs.
- Removing the Azure Container App deployment.
- Changing the Azure Storage data model.
