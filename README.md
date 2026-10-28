# Agent Topology and SCC AI Protection

Complete lab guide, automation script, and agent source code for **Agent Topology and Security Command Center (SCC) AI Protection** on Google Cloud.

## Overview

In this lab, an enterprise multi-agent fleet spanning **Vertex AI Agent Runtime** (`github-agent`) and **Cloud Run** (`salesforce-agent`), along with an external **MCP Server** (`github-mcp`), is configured for:

1. **Distributed Tracing (Cloud Trace & OpenTelemetry):** Exporting `invocation`, `agent_run`, `call_llm`, and `execute_tool` spans via the Cloud Telemetry OTLP API (`telemetry.googleapis.com`).
2. **Unified Discovery (App Hub & Agent Registry):** Auto-discovering Agent Runtime workloads in App Hub and registering Cloud Run A2A agents and MCP servers in Agent Registry.
3. **Agent Topology Visualization:** Rendering the multi-runtime fleet and MCP tool edges from aggregated trace spans.
4. **SCC AI Protection & IAM Least-Privilege Remediation:** Detecting over-privileged agent service accounts (`roles/editor`), analyzing permission scope with Policy Analyzer, and right-sizing to least privilege.

---

## Repository Structure

```text
.
├── README.md                  # Full step-by-step lab walkthrough (Tasks 1–10)
├── solve_lab.sh               # Automated end-to-end execution script for all tasks
├── salesforce_card.json       # Downloaded A2A agent card for salesforce-agent
├── apex_labs/
│   └── lab2_prereqs.sh        # Prerequisite script to deploy baseline environment
└── agents/
    ├── github-agent/          # ADK agent deployed on Vertex AI Agent Runtime
    └── salesforce-agent/      # ADK A2A agent deployed on Cloud Run
```

---

## Task-by-Task Walkthrough

### Task 1. Prepare Your Environment

1. Set project, location, and organization variables:
   ```bash
   export PROJECT_ID=$(gcloud config get-value project)
   export LOCATION=us-central1
   gcloud config set project ${PROJECT_ID}
   export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
   export ORGANIZATION_ID=$(gcloud projects get-ancestors ${PROJECT_ID} --format=json | jq -r '.[] | select(.type=="organization") | .id')
   echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER}), Org: ${ORGANIZATION_ID}, Location: ${LOCATION}"
   ```

2. Copy pre-staged code and install `agents-cli`:
   ```bash
   gcloud storage cp -r gs://${PROJECT_ID}-bucket/apex_labs .
   gcloud storage cp -r gs://${PROJECT_ID}-bucket/agents .
   mkdir -p ~/.vscode
   gcloud storage cp -r gs://${PROJECT_ID}-bucket/settings.json ~/.vscode/

   export PATH="${HOME}/.local/bin:${PATH}"
   uvx google-agents-cli setup
   uv tool upgrade google-agents-cli
   agents-cli info
   ```

3. Confirm the fleet (`salesforce-agent` on Cloud Run and `github_agent` on Agent Runtime):
   ```bash
   gcloud run services list --project=${PROJECT_ID} --region=${LOCATION} --format="table(metadata.name)"
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
     | jq -r '(.reasoningEngines // [])[] | "\(.displayName)\t\(.name)"'
   ```

4. Enable the observability and discovery APIs:
   ```bash
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
     --project=${PROJECT_ID}
   ```

---

### Task 2. Export Traces to Cloud Trace

1. Inspect instrumentation in `agents/salesforce-agent/pyproject.toml` (`google-adk[gcp,otel-gcp]`) and `agents/salesforce-agent/app/app_utils/telemetry.py` (`get_gcp_exporters(enable_cloud_tracing=True)`).

2. Grant the **Cloud Telemetry Traces Writer** (`roles/telemetry.tracesWriter`) role to the `salesforce-agent` Cloud Run service account:
   ```bash
   export SF_SA=$(gcloud run services describe salesforce-agent --region=${LOCATION} --format='value(spec.template.spec.serviceAccountName)')
   export SF_SA=${SF_SA:-"${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"}

   gcloud projects add-iam-policy-binding ${PROJECT_ID} \
     --member="serviceAccount:${SF_SA}" \
     --role="roles/telemetry.tracesWriter" \
     --condition=None
   ```

3. Generate traffic against `github_agent` using `agents-cli run`:
   ```bash
   export GH_ENGINE=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
     | jq -r '(.reasoningEngines // [])[] | select(.displayName=="github-agent" or .displayName=="github_agent") | .name' | head -n 1)

   agents-cli run \
     --url "https://${LOCATION}-aiplatform.googleapis.com/v1/${GH_ENGINE}" \
     --mode adk \
     --app-name app \
     "Find the google/adk-python repository and list its open issues"
   ```

---

### Task 3. Confirm Agent Runtime Agents Are Already Discovered

1. List auto-discovered agents in Agent Registry:
   ```bash
   gcloud alpha agent-registry agents list --location=${LOCATION} --project=${PROJECT_ID} --format="table(displayName)"
   ```

2. Confirm App Hub classifies the reasoning engine workload as `AGENT`:
   ```bash
   export TOKEN=$(gcloud auth print-access-token)
   curl -s -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" \
     "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
     | jq -r '.discoveredWorkloads[] | "\(.workloadProperties.functionalType.type // "-")\t\(.workloadReference.uri)"'
   ```

---

### Task 4. Register the Cloud Run Agent (`salesforce-agent`)

1. Provision the Discovery Engine service identity and grant it `roles/run.invoker` on `salesforce-agent`:
   ```bash
   gcloud beta services identity create \
     --service=discoveryengine.googleapis.com \
     --project=${PROJECT_ID}

   gcloud run services add-iam-policy-binding salesforce-agent \
     --region=${LOCATION} \
     --project=${PROJECT_ID} \
     --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
     --role="roles/run.invoker"
   ```

2. Download the A2A agent card and register `salesforce-agent` in Agent Registry:
   ```bash
   export SF_URL=$(gcloud run services describe salesforce-agent --region=${LOCATION} --format='value(status.url)')
   export TOKEN=$(gcloud auth print-identity-token)
   curl -s -H "Authorization: Bearer ${TOKEN}" \
     "${SF_URL}/a2a/app/.well-known/agent-card.json" -o salesforce_card.json

   gcloud alpha agent-registry services create salesforce-agent \
     --location=${LOCATION} \
     --project=${PROJECT_ID} \
     --display-name="salesforce-agent" \
     --agent-spec-type=a2a-agent-card \
     --agent-spec-content="$(cat salesforce_card.json)"
   ```

---

### Task 5. Register the GitHub MCP Server (`github-mcp`)

1. Register the GitHub MCP server in Agent Registry with `no-spec` and `JSONRPC`:
   ```bash
   gcloud alpha agent-registry services create github-mcp \
     --location=${LOCATION} \
     --project=${PROJECT_ID} \
     --display-name="github-mcp" \
     --mcp-server-spec-type=no-spec \
     --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"
   ```

2. Verify registration:
   ```bash
   gcloud alpha agent-registry mcp-servers list --location=${LOCATION} --project=${PROJECT_ID}
   ```

---

### Task 6. View the Agent Topology Graph

In the Google Cloud Console:
1. Navigate to **Agent Platform > Agent Registry** (`us-central1`).
2. Select `github-agent` under the **Agents** tab.
3. Open the **Topology** tab to view the multi-runtime graph connecting the agents and the `github-mcp` server.

---

### Tasks 7, 8 & 9. SCC AI Protection, Policy Analyzer & Least-Privilege Remediation

1. **Task 7 (Simulate Over-Privilege):**
   ```bash
   export SF_SA=$(gcloud run services describe salesforce-agent --region=${LOCATION} \
     --format='value(spec.template.spec.serviceAccountName)')
   gcloud projects add-iam-policy-binding ${PROJECT_ID} \
     --member="serviceAccount:${SF_SA}" \
     --role="roles/editor" --condition=None
   ```

2. **Task 8 (Identify Scope in Policy Analyzer):**
   Query `serviceAccount:${SF_SA}` in **IAM & Admin > Policy Analyzer** to inspect the broad project-wide permissions granted by `roles/editor`.

3. **Task 9 (Remediate & Verify Least Privilege):**
   Ensure narrow runtime roles are present (`roles/aiplatform.user`, `roles/telemetry.tracesWriter`, `roles/logging.logWriter`, `roles/cloudtrace.agent`), remove `roles/editor`, and verify removal:
   ```bash
   gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
     --member="serviceAccount:${SF_SA}" \
     --role="roles/editor" --condition=None

   gcloud projects get-iam-policy ${PROJECT_ID} \
     --flatten="bindings[].members" \
     --filter="bindings.members:${SF_SA} AND bindings.role:roles/editor" \
     --format="value(bindings.role)"
   ```
