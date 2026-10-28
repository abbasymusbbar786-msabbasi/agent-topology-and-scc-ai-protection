#!/usr/bin/env bash
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export LOCATION="${LOCATION:-us-central1}"
gcloud config set project "${PROJECT_ID}"
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
export PATH="${HOME}/.local/bin:${PATH}"

echo "=== Task 1: Enable Observability & Discovery APIs ==="
gcloud services enable \
  observability.googleapis.com \
  cloudtrace.googleapis.com \
  telemetry.googleapis.com \
  apphub.googleapis.com \
  apptopology.googleapis.com \
  agentregistry.googleapis.com \
  cloudasset.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  discoveryengine.googleapis.com \
  --project="${PROJECT_ID}"

echo "=== Task 2: Grant Cloud Telemetry Traces Writer Role ==="
export SF_SA=$(gcloud run services describe salesforce-agent --region="${LOCATION}" --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)
export SF_SA="${SF_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

for role in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent roles/telemetry.tracesWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" \
    --role="${role}" \
    --condition=None --quiet >/dev/null
done

echo "=== Task 4: Grant Discovery Engine Invoker & Register salesforce-agent ==="
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}" || true

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

export SF_URL=$(gcloud run services describe salesforce-agent --region="${LOCATION}" --project="${PROJECT_ID}" --format='value(status.url)')
export TOKEN=$(gcloud auth print-identity-token)
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${SF_URL}/a2a/app/.well-known/agent-card.json" -o salesforce_card.json

gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --display-name="salesforce-agent" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content="$(cat salesforce_card.json)" || true

echo "=== Task 5: Register GitHub MCP Server ==="
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --display-name="github-mcp" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC" || true

echo "=== Task 9: Ensure Least Privilege on ${SF_SA} ==="
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/editor" --condition=None >/dev/null 2>&1 || true

echo "All tasks completed successfully!"
