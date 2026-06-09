#!/usr/bin/env bash
# team13 전용 Postgres 백업 S3 버킷 + IRSA(role/policy) 1회 프로비저닝.
#
# Prerequisites: AWS CLI, skala-student (또는 동등) IAM 권한.
#   · s3:CreateBucket, s3:PutLifecycleConfiguration, iam:CreateRole, iam:PutRolePolicy
#
# Usage:
#   ./scripts/provision-backup-s3.sh          # create/update
#   ./scripts/provision-backup-s3.sh --dry-run
#
# After success:
#   1) kubectl apply -f k8s/overlays/skala/serviceaccount-backup.yaml
#   2) ArgoCD sync (cronjob-pg-dump S3 export 포함)
#   3) kubectl create job --from=cronjob/axis-pg-dump axis-pg-dump-manual -n skala3-finalproj-class3-team13
set -euo pipefail

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-881490135253}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
BUCKET="${BACKUP_S3_BUCKET:-axis-team13-backups}"
ROLE_NAME="${BACKUP_IAM_ROLE:-axis-team13-backup-sa}"
POLICY_NAME="${ROLE_NAME}-s3"
NAMESPACE="${NAMESPACE:-skala3-finalproj-class3-team13}"
SA_NAME="${BACKUP_SA_NAME:-axis-backup-sa}"
OIDC_ID="${EKS_OIDC_ID:-96BD83E8CE5CE0396D006BC5CEB350B0}"
DRY_RUN=false

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "==> S3 bucket: s3://${BUCKET} (${AWS_REGION})"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    bucket exists"
else
  run aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
fi

run aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

run aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

run aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-pg-dumps-14d",
      "Status": "Enabled",
      "Filter": {"Prefix": "pg/"},
      "Expiration": {"Days": 14}
    }]
  }'

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com",
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}"
      }
    }
  }]
}
EOF
)

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET}",
      "Condition": {
        "StringLike": {"s3:prefix": ["pg/*"]}
      }
    },
    {
      "Sid": "ObjectRW",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::${BUCKET}/pg/*"
    }
  ]
}
EOF
)

echo "==> IAM role: ${ROLE_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  run aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  run aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
fi

run aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$S3_POLICY"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "✓ Provision complete"
echo "  Bucket:  s3://${BUCKET}/pg/"
echo "  Role:    ${ROLE_ARN}"
echo "  SA:      ${NAMESPACE}/${SA_NAME}"
echo ""
echo "Next:"
echo "  kubectl apply -f k8s/overlays/skala/serviceaccount-backup.yaml"
echo "  # role-arn 가 다르면 serviceaccount-backup.yaml annotation 수정"
