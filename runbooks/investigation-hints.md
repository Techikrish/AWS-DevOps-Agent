# Investigation Runbook — DevOps Agent Lab
## Pre-loaded Guidance for AWS DevOps Agent

This runbook is uploaded to the Agent Space as a **Custom Skill** to pre-load
investigation hints. The agent uses this context when triaging incidents in
the `chaos-lab` namespace.

---

## Cluster Context

**Cluster:** devops-agent-lab-dev  
**Namespaces in scope:** `chaos-lab`, `kube-system`  
**Primary workloads:** stress-app, api-gateway-app  
**Downstream dependencies:** slow-downstream Lambda function  

---

## Known Incident Patterns

### Pattern 1: OOMKill Loop (stress-app)

**Symptoms:**
- Pod restart count > 5 in 10 minutes
- `kubectl describe pod` shows `OOMKilled` as last termination reason
- CloudWatch alarm: `devops-agent-lab-dev-eks-oom-killed` firing

**Root Cause Path:**
1. Check pod resource limits: `kubectl get pod <pod> -o yaml | grep -A5 resources`
2. Compare memory limit vs actual process memory demand
3. Check if the deployment has a recent `helm upgrade` event
4. Look at Helm values file diff in GitHub — the `memory.limits` field

**Expected Finding:** Container memory limit (64Mi) is insufficient for the
stress process (requesting 256MB). This is a misconfiguration in Helm values.

**Recommended Fix:**
```yaml
resources:
  limits:
    memory: "512Mi"   # Must exceed the process memory demand
  requests:
    memory: "256Mi"   # Match actual process demand
```

**Additional Gaps to Flag:**
- No PodDisruptionBudget on this deployment
- All replicas may be on a single AZ — check node topology labels
- No readiness probe — pod receives traffic even before it's healthy

---

### Pattern 2: Deployment Regression (bad Helm push)

**Symptoms:**
- ImagePullBackOff on pods in `chaos-lab` namespace
- Error rate spike on ALB target group shortly after a GitHub Actions deployment
- `kubectl get events -n chaos-lab` shows `Failed to pull image` errors

**Root Cause Path:**
1. Check recent GitHub Actions workflow runs — look for the `Deploy Stress App` workflow
2. Identify which commit triggered the deploy and what values file was used
3. Compare `image.tag` in current Helm release vs previous
4. Check if `/healthz` endpoint exists in the container image

**Expected Finding:** The deployment used `values-broken.yaml` which specifies
image tag `1.99-nonexistent` (does not exist in registry). Also: liveness probe
path changed from `/health` to `/healthz`.

**Recommended Fix:**
- Roll back via: `helm rollback stress-app 1 -n chaos-lab`
- Fix values file to use valid image tag: `nginx:1.25-alpine`
- Restore liveness probe path to `/health`

---

### Pattern 3: Lambda Timeout (slow-downstream)

**Symptoms:**
- CloudWatch alarm: `devops-agent-lab-dev-lambda-timeout` firing
- Lambda Errors metric > 3 per minute
- X-Ray traces show duration > 3000ms on `slow-downstream` function

**Root Cause Path:**
1. Check Lambda `Duration` metric — is P99 approaching the configured timeout?
2. Check CloudWatch Logs for `Task timed out after` messages
3. Check `ARTIFICIAL_DELAY_MS` environment variable — current value is 4500ms
4. Lambda timeout is configured at 3s — delay exceeds timeout by 1.5s

**Expected Finding:** Lambda environment variable `ARTIFICIAL_DELAY_MS=4500`
causes a 4.5s sleep, but the function timeout is set to 3s. Every invocation
will time out.

**Recommended Fix (two options):**
- Option A: Increase Lambda timeout to ≥ 10s and investigate the underlying slow operation
- Option B: Fix the actual slow operation — the 4.5s delay is artificial/a bug

---

### Pattern 4: Cascade Failure

**Symptoms:**
- Multiple alarms firing simultaneously
- `api-gateway-app` pods in CrashLoopBackOff or Pending state
- HPA scaling events happening but pod count not stabilizing
- Both `stress-app` AND `slow-downstream-lambda` showing errors

**Root Cause Path:**
1. Start with topology view — identify all services `api-gateway-app` depends on
2. Check `upstream-routing` ConfigMap — which endpoints are configured?
3. Investigate each upstream independently (stress-app → OOMKill, Lambda → timeout)
4. Check HPA events — scaling is masking the real issue (both upstreams broken)

**Expected Finding:** Two simultaneous root causes:
1. stress-app is OOMKilling (Pattern 1)
2. slow-downstream Lambda is timing out (Pattern 3)
The `api-gateway-app` depends on both and cannot route successfully.
HPA thrashing is a symptom, not a cause.

**Key Insight for Agent:** The blast radius is one user-visible service
(api-gateway), but the root cause is two independent failures in its
dependencies. Resolving either one alone will not restore service.

---

## Investigation Tooling Reference

| Tool | Purpose | How Agent Should Use It |
|------|---------|------------------------|
| CloudWatch Container Insights | Pod-level metrics, OOMKill events | Query `node_memory_utilization` namespace |
| CloudWatch Logs Insights | Application log analysis | Query `/aws/devops-agent-lab/dev/app` |
| GitHub Actions | Deployment history | Cross-reference deployment timestamps with incident start |
| X-Ray | Distributed trace latency | Identify which service segment is slow |
| kubectl (via topology) | Live pod status | `describe pod`, `get events` in `chaos-lab` |

---

## Escalation Path

If the agent cannot determine root cause within 15 minutes:
1. Page the on-call engineer via PagerDuty policy: `devops-agent-lab-oncall`
2. Post investigation summary to `#incidents-devops-agent-lab` Slack channel
3. Create ServiceNow ticket with investigation timeline attached

---

*This runbook is maintained as part of the Production Infrastructure Series.*
*GitHub: aws-devops-agent-lab | Last updated: 2026-04-02*
