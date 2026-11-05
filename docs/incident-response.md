# Incident Response: what do we do if credentials are leaked?

The short version of the answer, for the case where a credential of this
project shows up somewhere it should not be: a commit, a log, a chat message,
an issue, or someone tells us it was used without authorization.

It answers three questions, in this order:

1. **How do we rotate credentials?**
2. **How do we check for unauthorized access?**
3. **How do we notify stakeholders?**

The order is not a style choice. Rotating before you know the scope leaves
the other copy of the credential alive; checking before you rotate means you
read the audit trail while the attacker is still reading it too.

The long-form operating procedures (pipeline, pods, TLS, disks, metrics)
live in [runbook.md](runbook.md). The audit trail itself, the alarms and the
threat detection are documented in [security.md](security.md).

---

## 0. What is actually exposed in this project

Knowing the inventory makes the triage fast:

| Credential | Where it lives | How it reaches the app |
|---|---|---|
| OpenAI API key | AWS Secrets Manager `journal-api/credentials/llm` | init container reads it, writes it to an `emptyDir` with mode `0600` |
| Postgres password | AWS Secrets Manager `journal-api/credentials/database` | same, as `DATABASE_URL` |
| AWS access keys of `rodri-dev` | IAM (2 active keys, `AdministratorAccess`) | only used from a workstation; never in CI |
| GitHub Actions | **none** | OIDC: GitHub assumes `journal-github-actions` with a short-lived token |
| Instance role | IMDSv2 on EC2 | read by the pods; the port 22 is closed and there is no SSH key anywhere |

Two consequences:

- **CI has no static credential.** A leaked GitHub token is an OIDC token
  that expires in an hour, and rotating means editing the trust policy.
- **`rodri-dev` is the whole account.** It carries `AdministratorAccess`.
  If one of its access keys leaks, the attack surface is the entire AWS
  account, not just this project.

---

## 1. Confirm the scope

Before rotating anything, find out **what** leaked and **where** it is
still alive. Deleting a secret from a file does not revoke it: the value
lives on in the git history, in the S3 versions, and in the old versions of
the SSM parameters.

```bash
# Is the secret in the git history? (the CI scans the whole history)
./gitleaks detect --source . --redact --no-banner --verbose

# Is it in a Kubernetes Secret, a ConfigMap or a pod spec?
kubectl -n journal-api get secret journal-secrets -o jsonpath='{.data}' | sed 's/./*/g'

# Did it end up in the application logs?
aws logs filter-log-events --log-group-name /aws/journal-api/application \
  --filter-pattern '"OPENAI_API_KEY"'
```

**Expected output:** a list of places. One place = one rotation. Several
places = rotating is not enough; every place has to be cleaned.

---

## 2. Rotate at the source, in the right order

The general rule for every credential type: **create the new one, verify it
works, and only then revoke the old one.** Revoking first leaves no way
back if the new credential is wrong, and it takes the application down while
you fix it.

| Credential | Order |
|---|---|
| **Postgres password** | 1) change the password **in the database** → 2) update the secret → 3) redeploy → 4) verify |
| **OpenAI API key** | 1) generate the new key → 2) write it to Secrets Manager → 3) redeploy → 4) verify → 5) **revoke the old key** |
| **AWS access key** | 1) create the new key → 2) attach it to the principal → 3) verify it works → 4) **deactivate the old key** → 5) delete it |
| **GitHub OIDC** | there is no secret to rotate: narrow the trust policy in `terraform/main.tf` and re-apply |

For the Postgres password, the order matters more than for the others:
changing it only in the secret leaves the app unable to connect, and
changing it only in the database leaves the secret out of sync. The correct
order is database → secret → redeploy.

The commands for the two application secrets:

```bash
# OpenAI key: the value never goes through the repo, a file or a chat.
printf '%s' "$NUEVA_KEY" | ./scripts/migrate-secrets.sh --set-llm-key

# Postgres password: first in the database, then in the secret.
read -rsp "Nueva password: " NEWPW; echo
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["kubectl -n journal-api exec deploy/postgres -- psql -U postgres -d career_journal -c \"ALTER USER postgres WITH PASSWORD '"'"'$NEWPW'"'"'\""]'
./scripts/migrate-secrets.sh

# Then redeploy so the pods pick up the new value.
gh workflow run ci.yml --ref main
```

For an AWS access key:

```bash
aws iam create-access-key --user-name rodri-dev
# ... use the new key and verify it works ...
aws iam update-access-key --user-name rodri-dev --access-key-id <OLD_ID> --status Inactive
aws iam delete-access-key --user-name rodri-dev --access-key-id <OLD_ID>
```

---

## 3. Revoke the exposed credential

Until this step, the old credential **still works**. This is not negotiable.

- **OpenAI**: revoke the key in the provider's dashboard.
- **AWS**: deactivate the access key, then delete it.
- **Postgres**: already covered by step 2 (the password changed in the
  database is the revocation).

Deleting the value from a git commit, a log line or an SSM parameter is
*not* revocation. SSM keeps the previous versions for about 30 days.

---

## 4. Check for unauthorized access

This is the question that **cannot be answered without the audit trail**.
CloudTrail records every API call in the account; the copy in CloudWatch
Logs can be queried in seconds.

```bash
# Who read the secrets of the project?
aws logs start-query \
  --log-group-name aws-cloudtrail-logs-journal-api \
  --start-time "$(($(date +%s) - 604800))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, eventName, userIdentity.arn as principal, userIdentity.type as tipo, sourceIPAddress, requestParameters.secretId as secret
    | filter eventName = "GetSecretValue"
    | sort @timestamp desc | limit 50'

# Were there failed console logins?
aws logs start-query \
  --log-group-name aws-cloudtrail-logs-journal-api \
  --start-time "$(($(date +%s) - 604800))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress, errorMessage
    | filter eventName = "ConsoleLogin"
    | sort @timestamp desc | limit 50'

# Did anyone create credentials or escalate privileges?
aws logs start-query \
  --log-group-name aws-cloudtrail-logs-journal-api \
  --start-time "$(($(date +%s) - 604800))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress
    | filter eventName in ["CreateAccessKey","CreateUser","AttachUserPolicy","PutUserPolicy","UpdateAssumeRolePolicy"]
    | sort @timestamp desc | limit 50'
```

The same three questions are saved as queries in Terraform
(`journal-api/audit-lectura-de-secretos`, `journal-api/audit-console-login`,
`journal-api/audit-cambios-de-sg`) and can be run from the console under
**CloudWatch → Logs Insights → Saved queries**.

### How to read the result

| What you see | What it means | What to do |
|---|---|---|
| `GetSecretValue` by `AssumedRole` | the deploy reading its own secrets | normal, not an incident |
| `GetSecretValue` by `IAMUser` | **a leaked key in use** | revoke (step 3), rotate (step 2), follow the `sourceIPAddress` |
| `ConsoleLogin` with `Failed authentication` | someone guessing or trying | count the IPs; escalate if they are not yours |
| `CreateAccessKey` / `AttachUserPolicy` | privilege escalation | revoke the key, detach the policy, escalate |
| A `sourceIPAddress` you do not recognize | unknown actor | escalate; in this project the real impact is the **database**, so the Postgres password is the first thing to change |

The alarms watch the same events, so most of the time you get told before
you have to look:

| Alarm | What it means |
|---|---|
| `journal-api-security-secret-read` | a secret was read by a principal that is not a role |
| `journal-api-security-console-login-failed` | failed console logins |
| `journal-api-security-iam-credential-change` | an IAM credential was created or escalated |
| `journal-api-security-sg-changed` | someone opened or closed a port on the API |
| `journal-api-config-noncompliant` (via SNS) | AWS Config found a resource that no longer complies with a security rule |

---

## 5. Notify stakeholders

The channel already exists: the SNS topic `journal-api-alarms`, with a
confirmed email subscription. To publish the incident notice:

```bash
aws sns publish \
  --topic-arn "$(terraform -chdir=terraform output -raw sns_alarms_topic_arn)" \
  --subject "INCIDENT: leaked credential rotated" \
  --message "Leaked: <what>. Rotated: <what>. Unauthorized access: <findings>. Pending: <what>."
```

**The message has to answer three things:** what leaked, what has already
been done, and what is still pending. Without the last one the notice is
useless: nobody knows whether they can go to sleep.

Escalation order:

1. **Owner of the project.**
2. **Provider of the credential** (OpenAI, AWS Support) if the use was real.
3. **Stakeholders**, if the secret gave access to third-party data.
4. **The team**, if the incident leaves the lab environment.

---

## 6. Postmortem

Five questions, in the repo or in an issue:

1. How did the credential reach a place it should not be? (commit, log,
   chat, issue)
2. What detected it, and how long did it take? (gitleaks in the CI, the
   alarm, a human)
3. How long was it exposed? (commit date → revocation date)
4. What contained the damage? (role-based identity with an `ExternalId`,
   the explicit denial of direct access to the secrets, the security group
   without port 22, the audit trail)
5. Which control is missing? (the answer goes to the backlog: a new
   control, a new alarm, one more step in the CI)

**The usual cause in a project like this:** a secret written into a `.env`
file or into a shell command. The correct pattern is
`printf '%s' "$NUEVA_KEY" | ./scripts/migrate-secrets.sh --set-llm-key`:
the value never goes through the repo, a file, or a chat channel.

---

## Quick reference

```bash
# The audit trail
aws cloudtrail describe-trails --query "trailList[].Name"
aws cloudtrail describe-trails --query "trailList[].{S3:S3BucketName,Logs:CloudWatchLogsLogGroupArn,KMS:KmsKeyId}"

# The alarms (all of them, with their state)
aws cloudwatch describe-alarms --alarm-name-prefix journal-api \
  --query "MetricAlarms[].[AlarmName,StateValue]" --output table

# The threat detection (AWS Config rules and their compliance)
aws config describe-config-rules --query "ConfigRules[].[ConfigRuleName,ConfigRuleState]" --output table
aws config get-compliance-summary-by-config-rule

# The IAM users of the account (the credential surface)
aws iam list-users
aws iam list-access-keys --user-name rodri-dev

# The identity of this project is roles, not keys
aws sts get-caller-identity
```

---

## References

- [security.md](security.md): the audit trail, the security alarms, the AWS
  Config rules and the verification of each of them.
- [runbook.md](runbook.md): the operating runbook (pipeline, pods, TLS,
  metrics, disks).
- [observability.md](observability.md): the telemetry pipeline and the
  application metrics.
- [delivery.md](delivery.md): how the secrets travel from the provider's
  dashboard to the process that uses them.
