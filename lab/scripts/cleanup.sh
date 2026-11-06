#!/usr/bin/env bash
# Remove somente a integracao identificada pelo estado local do laboratorio.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
MODE=${1:-plan}
[[ "$MODE" == plan || "$MODE" == apply ]] || { echo 'Uso: bash scripts/cleanup.sh [plan|apply]' >&2; exit 1; }
for tool in oci gh jq sed sha256sum; do
  command -v "$tool" >/dev/null || { echo "Instale $tool." >&2; exit 1; }
done
STATE=.state/resources.json
CONTEXT=.generated/context.json
PROGRESS=.state/cleanup.json
[[ -f config/lab.env && -f "$STATE" && -f "$CONTEXT" ]] || { echo 'Use a mesma pasta do apply, com lab.env, .state e .generated preservados.' >&2; exit 1; }
source <(sed 's/\r$//' config/lab.env)
OCI_DOMAIN_URL=${OCI_DOMAIN_URL%/}
if jq -e '.cleanup_complete == true' "$STATE" >/dev/null; then
  echo 'A limpeza da integracao ja foi concluida. Para novo lab, use outra copia limpa.'
  exit 0
fi
[[ -n "${OCI_ADMIN_PROFILE:-}" && -n "${OCI_ADMIN_AUTH:-}" ]] || { echo 'Configure o profile administrativo.' >&2; exit 1; }
FINGERPRINT=$(jq -Sc . "$CONTEXT" | sha256sum | cut -d ' ' -f 1)
[[ "$FINGERPRINT" == "$(jq -r '.context_sha256 // empty' "$STATE")" ]] || { echo 'O contexto nao corresponde ao estado salvo. Limpeza interrompida.' >&2; exit 1; }
REPOSITORY=$(jq -er '.repository' "$CONTEXT")
DOMAIN_URL=$(jq -er '.domain_url' "$CONTEXT")
IAM_REGION=$(jq -er '.iam_region' "$CONTEXT")
[[ "${GITHUB_REPOSITORY:-}" == "$REPOSITORY" && "${OCI_DOMAIN_URL:-}" == "$DOMAIN_URL" ]] || { echo 'lab.env aponta para outro repositorio ou dominio. Use a configuracao original.' >&2; exit 1; }
APP_ID=$(jq -r '.app_id // empty' "$STATE")
TRUST_ID=$(jq -r '.trust_id // empty' "$STATE")
POLICY_ID=$(jq -r '.policy_id // empty' "$STATE")
GITHUB_CONFIGURED=$(jq -r '.github_configuration_started // false' "$STATE")
oci_admin() { command oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --output json "$@"; }
done_step() { [[ -f "$PROGRESS" ]] && jq -e --arg key "$1" '.[$key] == true' "$PROGRESS" >/dev/null; }
mark_step() {
  jq --arg key "$1" '.[$key] = true' "$PROGRESS" > .state/cleanup.tmp
  mv -- .state/cleanup.tmp "$PROGRESS"
}
run_step() {
  local key=$1
  shift
  if ! done_step "$key"; then
    "$@"
    mark_step "$key"
  fi
}
trap 'echo "Limpeza interrompida. Os passos concluidos ficam em .state/cleanup.json; corrija a causa e repita cleanup.sh apply." >&2' ERR

# Conferir os nomes dos recursos pelos IDs salvos, antes de excluir algo.
if [[ -n "$APP_ID" ]] && ! done_step app_deleted; then
  oci_admin identity-domains app get --endpoint "$DOMAIN_URL" --app-id "$APP_ID" --attributes id,name,displayName > .generated/cleanup-app.json
  jq -e --slurpfile c "$CONTEXT" --slurpfile s "$STATE" '.data.id == $s[0].app_id and .data.name == $s[0].client_id and (.data["display-name"] // .data.displayName) == $c[0].app_name' .generated/cleanup-app.json >/dev/null
fi
if [[ -n "$TRUST_ID" ]] && ! done_step trust_deleted; then
  oci_admin identity-domains identity-propagation-trust get --endpoint "$DOMAIN_URL" --identity-propagation-trust-id "$TRUST_ID" > .generated/cleanup-trust.json
  jq -e --slurpfile c "$CONTEXT" '.data.name == $c[0].trust_name and .data.issuer == "https://token.actions.githubusercontent.com"' .generated/cleanup-trust.json >/dev/null
fi
if [[ -n "$POLICY_ID" ]] && ! done_step policy_deleted; then
  oci_admin iam policy get --region "$IAM_REGION" --policy-id "$POLICY_ID" > .generated/cleanup-policy.json
  jq -e --slurpfile c "$CONTEXT" '.data.name == $c[0].policy_name and .data["compartment-id"] == $c[0].compartment_ocid' .generated/cleanup-policy.json >/dev/null
fi
gh workflow list --repo "$REPOSITORY" --all --json id,path > .generated/cleanup-workflows.json
WORKFLOW_ID=$(jq -r '[.[] | select(.path == ".github/workflows/oci-wif-integration.yml")][0].id // empty' .generated/cleanup-workflows.json)
VARIABLES=(OCI_CLIENT_ID OCI_REGION OCI_DOMAIN_URL OCI_NAMESPACE OCI_BUCKET EXPECTED_REPOSITORY EXPECTED_BRANCH OIDC_AUDIENCE OCI_RES_TYPE)
if [[ "$GITHUB_CONFIGURED" == true ]]; then
  gh variable list --repo "$REPOSITORY" --json name > .generated/cleanup-variables.json
  gh secret list --repo "$REPOSITORY" --json name > .generated/cleanup-secrets.json
fi
jq -n --arg repository "$REPOSITORY" --arg domain_url "$DOMAIN_URL" --arg app_id "$APP_ID" --arg trust_id "$TRUST_ID" --arg policy_id "$POLICY_ID" --arg workflow_id "$WORKFLOW_ID" --argjson github_configured "$GITHUB_CONFIGURED" --argjson variables "$(printf '%s\n' "${VARIABLES[@]}" | jq -R . | jq -s .)" '{repository:$repository,domain_url:$domain_url,app_id:$app_id,trust_id:$trust_id,policy_id:$policy_id,workflow_id:$workflow_id,remove_github_configuration:$github_configured,github_variables:$variables,github_secret:"OCI_CLIENT_SECRET",preserved:["bucket e objetos","compartment","Identity Domain","repositorio GitHub e historico","arquivos locais"]}' > .generated/cleanup-plan.json
cat .generated/cleanup-plan.json
if [[ "$MODE" == plan ]]; then
  echo 'Plan de limpeza concluido. Nenhum recurso foi removido.'
  echo 'Para executar: bash scripts/cleanup.sh apply'
  exit 0
fi
[[ -f "$PROGRESS" ]] || printf '{}\n' > "$PROGRESS"
jq '.cleanup_started = true' "$STATE" > .state/resources.tmp
mv -- .state/resources.tmp "$STATE"
if [[ -n "$WORKFLOW_ID" ]]; then
  run_step workflow_disabled gh workflow disable "$WORKFLOW_ID" --repo "$REPOSITORY"
fi
if [[ -n "$APP_ID" ]]; then
  run_step app_disabled oci_admin identity-domains app-status-changer put --endpoint "$DOMAIN_URL" --app-status-changer-id "$APP_ID" --active false --schemas '["urn:ietf:params:scim:schemas:oracle:idcs:AppStatusChanger"]' --force >/dev/null
fi
if [[ -n "$POLICY_ID" ]]; then
  run_step policy_deleted oci_admin iam policy delete --region "$IAM_REGION" --policy-id "$POLICY_ID" --force >/dev/null
fi
if [[ -n "$TRUST_ID" ]]; then
  run_step trust_deleted oci_admin identity-domains identity-propagation-trust delete --endpoint "$DOMAIN_URL" --identity-propagation-trust-id "$TRUST_ID" --force >/dev/null
fi
if [[ -n "$APP_ID" ]]; then
  run_step app_deleted oci_admin identity-domains app delete --endpoint "$DOMAIN_URL" --app-id "$APP_ID" --force >/dev/null
fi
if [[ "$GITHUB_CONFIGURED" == true ]]; then
  if ! done_step secret_deleted; then
    if jq -e 'any(.[]; .name == "OCI_CLIENT_SECRET")' .generated/cleanup-secrets.json >/dev/null; then
      run_step secret_deleted gh secret delete OCI_CLIENT_SECRET --repo "$REPOSITORY"
    else
      mark_step secret_deleted
    fi
  fi
  for name in "${VARIABLES[@]}"; do
    if ! done_step "variable_$name"; then
      if jq -e --arg name "$name" 'any(.[]; .name == $name)' .generated/cleanup-variables.json >/dev/null; then
        run_step "variable_$name" gh variable delete "$name" --repo "$REPOSITORY"
      else
        mark_step "variable_$name"
      fi
    fi
  done
fi
jq '.cleanup_complete = true' "$STATE" > .state/resources.tmp
mv -- .state/resources.tmp "$STATE"
echo 'Integracao removida. Bucket, compartment, dominio e repositorio preservados.'
echo 'Conserve o estado para consulta; para outro laboratorio, use uma copia limpa.'
