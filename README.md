# aws devops agent lab

**A testbed for AWS DevOps Agent — featuring four chaos scenarios, a reusable Terraform module, and real investigation output.**

> Part of the [Production Infrastructure Series](https://medium.com/@krishnafattepurkar) on Medium.

[![Terraform](https://img.shields.io/badge/Terraform-≥1.6-7B42BC?logo=terraform)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-DevOps_Agent_GA-FF9900?logo=amazonaws)](https://aws.amazon.com/devops-agent/)
[![EKS](https://img.shields.io/badge/Kubernetes-EKS-326CE5?logo=kubernetes)](https://aws.amazon.com/eks/)

---

## What This Is

AWS DevOps Agent tested against real-world failure patterns. This repo is a **deliberately broken EKS environment** designed 

It contains:

- **Terraform module** — provisions Agent Space IAM roles, CloudWatch alarms, SNS routing, and Lambda function as code (no console clicking)
- **Four chaos scenarios** — escalating from a single OOMKill to a multi-service cascade failure
- **Investigation runbook** — uploaded as a Custom Skill to the Agent Space
- **GitHub Actions workflow** — simulates a deployment regression the agent can correlate

Read the full walkthrough: [Medium Article — Production Infrastructure Series](#)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    AWS DevOps Agent Space                    │
│                                                              │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │  Topology   │    │  Triage      │    │  RCA Agent     │  │
│  │  Map (auto) │───▶│  Agent       │───▶│                │  │
│  └─────────────┘    └──────────────┘    └────────────────┘  │
│         │                                        │           │
│         ▼                                        ▼           │
│  ┌─────────────┐                      ┌────────────────┐    │
│  │ CloudWatch  │                      │  Mitigation    │    │
│  │ Datadog/etc │                      │  Plan + Slack  │    │
│  └─────────────┘                      └────────────────┘    │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│                   chaos-lab Namespace (EKS)                  │
│                                                              │
│  stress-app ──────────────────────────────────────────────  │
│  (Scenario 1: OOMKill, Scenario 4: Cascade source 1)        │
│                                                              │
│  api-gateway-app ─────────────────────────────────────────  │
│  (Scenario 2: Bad deploy, Scenario 4: Cascade target)       │
│                                                              │
│  slow-downstream (Lambda) ────────────────────────────────  │
│  (Scenario 3: Timeout, Scenario 4: Cascade source 2)        │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- AWS account with DevOps Agent enabled (us-east-1)
- EKS cluster (1.28+) with Container Insights enabled
- Terraform ≥ 1.6
- kubectl + Helm 3.x
- GitHub repo (for CI/CD correlation in Scenario 2)

---

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/your-org/aws-devops-agent-lab.git
cd aws-devops-agent-lab/terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your cluster name and GitHub repo
```

Set secrets as environment variables — never hardcode them:

```bash
export TF_VAR_github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
export TF_VAR_slack_webhook_url="https://hooks.slack.com/services/xxx"
```

### 2. Apply Terraform

```bash
terraform init
terraform plan
terraform apply
```

The output will print the execution role ARN and next steps:

```
next_steps = <<EOT
============================================================
NEXT STEPS — AWS DevOps Agent Lab Setup
============================================================
1. Go to AWS Console → DevOps Agent → Create Agent Space
2. Paste the execution role ARN: arn:aws:iam::123456789:role/...
3. Connect CloudWatch using SNS topic: arn:aws:sns:...
4. Connect GitHub using token from SSM: /devops-agent-lab/dev/github-token
5. Enable topology scan on cluster: your-cluster-name
...
```

### 3. Deploy the lab workloads

```bash
kubectl apply -f eks/app/deployment.yaml
kubectl apply -f eks/app/service.yaml
```

### 4. Upload the runbook as a Custom Skill

In the Agent Space web app:
- Navigate to **Skills → Custom Skills → Create**
- Paste the contents of `runbooks/investigation-hints.md`
- Set skill type to: `Incident RCA, Incident Triage`

---

## Running the Chaos Scenarios

### Scenario 1 — OOMKill

```bash
kubectl apply -f eks/chaos/oom-break.yaml

# Watch the carnage
kubectl get pods -n chaos-lab -w

# What you'll see:
# stress-app-xxx   0/1   OOMKilled   3   45s
# stress-app-xxx   0/1   Pending     3   46s
# stress-app-xxx   0/1   Running     4   48s  ← restart loop
```

**Wait:** Agent should start investigating within 60s of the CloudWatch alarm.

**Expected agent output:**
- Root cause: memory limit (64Mi) insufficient for process (256MB)
- Recommendation: increase `resources.limits.memory` to ≥ 512Mi
- Additional flags: missing PDB, single-AZ placement

---

### Scenario 2 — Deployment Regression

```bash
# Push to the chaos branch to trigger the bad GitHub Actions deployment
git checkout -b chaos-scenario-2
git push origin chaos-scenario-2

# Or trigger manually in GitHub Actions → bad-deploy.yml → Run workflow
```

**What happens:** The workflow deploys `values-broken.yaml` with a nonexistent
image tag. Pods go to ImagePullBackOff. Agent correlates the deployment timestamp
with the error spike.

**Expected agent output:**
- Root cause: `image.tag: 1.99-nonexistent` does not exist in registry
- Deployment correlation: GitHub Actions run #X at HH:MM:SS matches incident start
- Recommendation: rollback to previous Helm revision

---

### Scenario 3 — Lambda Timeout

```bash
# Get the Lambda URL from Terraform output
LAMBDA_URL=$(terraform output -raw lambda_function_url -chdir=terraform)

# Trigger it repeatedly — each call will timeout after 3s
for i in {1..10}; do
  curl -s "$LAMBDA_URL" &
done
wait
echo "All 10 calls timed out (expected)"
```

**Expected agent output:**
- Root cause: `ARTIFICIAL_DELAY_MS=4500` exceeds Lambda timeout of 3000ms
- X-Ray trace correlation: latency consistently at 3s cutoff
- Recommendation: increase timeout to ≥10s OR investigate slow operation

---

### Scenario 4 — Cascade Failure

First, get the Lambda URL and update the ConfigMap:

```bash
LAMBDA_URL=$(terraform output -raw lambda_function_url -chdir=terraform)
sed -i "s|REPLACE_WITH_LAMBDA_FUNCTION_URL|$LAMBDA_URL|g" eks/chaos/cascade-break.yaml
```

Then trigger both upstream failures simultaneously:

```bash
# Apply Scenario 1 (OOMKill) first
kubectl apply -f eks/chaos/oom-break.yaml

# Wait 30 seconds, then apply cascade
sleep 30
kubectl apply -f eks/chaos/cascade-break.yaml

# Trigger Lambda timeouts concurrently
for i in {1..20}; do curl -s "$LAMBDA_URL" & done
```

**This is the real test.** The agent must:
1. Identify two simultaneous root causes (OOMKill + Lambda timeout)
2. Correlate them to a single user-visible failure (api-gateway)
3. Recognize that HPA scaling is a symptom, not a cause
4. Provide separate mitigation steps for each root cause

---

## Resetting the Environment

```bash
# Remove all chaos manifests
kubectl delete -f eks/chaos/
kubectl delete -f eks/app/

# Reset to clean state
kubectl delete namespace chaos-lab

# Reapply base workloads (good config)
kubectl apply -f eks/app/
```

---

## Cleanup

```bash
cd terraform
terraform destroy
```

---

## What the Agent Flagged (Beyond the Obvious)

After running all four scenarios, the agent's **proactive recommendations** surfaced structural gaps that no alarm was monitoring:

1. `stress-app` has no PodDisruptionBudget — rolling updates can cause full outages
2. All `chaos-lab` pods landed on a single AZ — missing `topologySpreadConstraints`
3. No multi-AZ deployment for any workload in the namespace
4. Lambda function has no reserved concurrency — can be throttled by other functions
5. CloudWatch log retention is 14 days — insufficient for trend analysis the agent recommends

These weren't in any runbook. The agent found them by analyzing patterns across the incident history.

---

## Project Structure

```
aws-devops-agent-lab/
├── terraform/
│   ├── main.tf                    # Agent Space IAM, CloudWatch alarms, SNS
│   ├── lambda.tf                  # slow-downstream Lambda function
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── eks/
│   ├── app/
│   │   ├── deployment.yaml        # stress-app (memory misconfigured)
│   │   └── service.yaml           # api-gateway-app (cascade target)
│   ├── chaos/
│   │   ├── oom-break.yaml         # Scenario 1: OOMKill trigger
│   │   └── cascade-break.yaml    # Scenario 4: Multi-service cascade
│   └── helm/
│       └── values-broken.yaml    # Scenario 2: Deployment regression
├── lambda/
│   └── timeout-scenario/
│       └── handler.py             # Scenario 3: Artificial latency
├── github-actions/
│   └── bad-deploy.yml             # Scenario 2: CI/CD deployment trigger
├── runbooks/
│   └── investigation-hints.md    # Custom Skill for Agent Space
└── README.md
```

---



---

*Part of the Production Infrastructure Series — a collection of battle-tested patterns for engineers running production workloads on AWS.*
