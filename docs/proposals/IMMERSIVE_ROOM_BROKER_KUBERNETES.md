# Immersive Room Broker on Kubernetes

**Status:** Implemented in templates and pipeline; not yet deployed.

## Goal

Run the existing Immersive Room WebSocket broker in this cluster, alongside
the Azure-hosted broker during a staged rollout. The Kubernetes deployment
should serve authenticated device and MCP clients over TLS at a stable
external WSS endpoint. The Azure deployment should remain available until
clients have been migrated and rollback has been verified.

## Existing Behavior

- The broker listens on TCP port `8765` and speaks WebSocket. Its current
  container image is built from `docker/Dockerfile.broker` in the Immersive
  Room project and published to the Immersive Room ACR.
- Static device/MCP principals are loaded from `TOKENS_FILE` (or
  `TOKENS_JSON`). Dynamically registered kiosk tokens and presence bindings
  can be persisted in Azure Table Storage or in local files.
- The current Jetson Agent Deployment sets `BROKER_URL` to the Azure staging
  endpoint. Deploying a broker in Kubernetes alone will not move that client
  or any other external consumers.
- The cluster's `web-dashboard` app provides the local pattern: a `home`
  namespace Deployment and ClusterIP Service, an HTTPRoute attached to
  `network/envoy-external`, image pulls through `acr-pull`, and an Argo CD
  Application for the generated app path.

## Proposed Design

Add a `broker` application under
`templates/config/kubernetes/apps/home/broker/`, following the structure of
[`web-dashboard`](../../templates/config/kubernetes/apps/home/web-dashboard/).
Register it with Argo CD in
`templates/config/kubernetes/argo/apps/home/broker.yaml.j2`.

The initial deployment should have one replica. Broker connection state and
the device registry are in memory, so multiple replicas would not share live
connections or routing state. Use the existing ARM64 node selector pattern
and `acr-pull` secret. The broker pipeline now publishes an ARM64 image; see
Image Publishing below.

Proposed Kubernetes resources:

- **Deployment:** ARM64 broker image, `BROKER_PORT=8765`,
  `TOKENS_FILE=/etc/immersive/tokens.json`, no service-account token, and
  TCP startup/readiness/liveness probes on port 8765. Use a `Recreate`
  strategy and conservative CPU/memory requests and limits.
- **Token Secret:** A SOPS-encrypted `broker-tokens` Secret containing the
  contents of `tokens.json`, mounted read-only at `/etc/immersive/tokens.json`
  (subPath). The file holds 8 principals: 2 devices (`desktop-1`, `jetson-1`)
  and 6 MCP principals. Do not commit plaintext tokens.
- **Service:** ClusterIP on TCP port `8765`; no direct NodePort or
  LoadBalancer exposure.
- **HTTPRoute:** Host `broker.#{ cloudflare_domain }#` through
  `envoy-external` HTTPS, forwarding to the broker Service. Verify WebSocket
  upgrade behavior and Cloudflare proxy timeouts with a real external client.
- **Persistent state:** A Longhorn PVC mounted at `/var/lib/immersive-room`,
  with `BROKER_KIOSK_TOKEN_FILE=/var/lib/immersive-room/kiosk-device-tokens.json`
  and `PRESENCE_ROUTES_FILE=/var/lib/immersive-room/presence-routes.json`.
  Azure Table Storage is not used; leave `AZURE_STORAGE_TABLE_URL` and
  `BROKER_KIOSK_TOKEN_TABLE_NAME` unset. Keep one replica.
- **Image configuration:** `bootstrap_apps.broker.image` is set to
  `immersiveroom.azurecr.io/immersive-room/broker:latest` for the first
  deployment, matching the other apps. Pin it to the build-number tag after the
  first successful pipeline run.

## Image Publishing

The broker stage in `azure-pipelines-broker-staging.yml` now builds and pushes
an amd64/arm64 manifest using Docker Buildx, preserving compatibility with the
existing Azure staging deployment. Pin the pipeline's build-number tag as
`bootstrap_apps.broker.image` before syncing the Argo application.

Client `BROKER_URL` values (Jetson, desktop, and the MCP servers) are changed
manually by the operator. This proposal does not modify any client
configuration. Keep the Azure endpoint and its configuration intact for
rollback until the cutover is complete.

## Decisions Before Implementation

1. **State backend (resolved):** Longhorn PVC. Azure Table Storage is not used.
2. **Initial clients (resolved):** Jetson, desktop, and the MCP servers. The
   operator changes each client's `BROKER_URL` manually.
3. **External hostname (resolved):** `broker.#{ cloudflare_domain }#` for the
   public WSS endpoint.
4. **Image publishing (resolved):** The broker pipeline builds and pushes
   `linux/amd64` and `linux/arm64` via Buildx.
5. **Bootstrap principals (resolved):** Use the local `tokens.json` (8
   principals) as the `broker-tokens` Secret. Kiosk tokens and presence bindings
   start empty on the PVC unless migrated from Azure.

## Implementation Sequence

1. Publish the multi-architecture broker image and set its immutable build tag
  in `bootstrap_apps.broker.image`.
2. Render the cluster configuration and review generated manifests and Secret
  encryption before syncing the Argo application.
3. Validate external WSS connectivity, authentication rejection for an
   invalid token, successful device registration and MCP-to-device routing,
   readiness behavior, and persistence across a pod restart.
4. Move one test client to the Kubernetes endpoint, monitor it, then migrate
   remaining clients in an agreed order. Retire the Azure broker only as a
   separate, explicit change.

## Rollback

Restore migrated clients' `BROKER_URL` values to the Azure endpoint and restart
those clients. Keep the Azure broker, its image, credentials, and state
available throughout the migration. Do not delete or overwrite Azure-backed
token or presence data as part of the Kubernetes deployment.

## Acceptance Criteria

- Argo CD can sync the app, and the single broker pod becomes Ready.
- A client outside the cluster can establish WSS through the external
  Gateway and Cloudflare path; invalid credentials are rejected.
- A valid test device registers and an authenticated MCP client can route a
  request to it and receive the response.
- Registered kiosk tokens and presence bindings survive a broker pod restart.
- At least one migrated client can be returned to Azure by changing its
  broker URL, without modifying or deleting Azure broker state.