#!/usr/bin/env bash
# Executar com bash; nao usar bash -x, para nao registrar credenciais.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
MODE=${1:-plan}
[[ "$MODE" == check || "$MODE" == plan || "$MODE" == apply ]] || { echo 'Uso: bash scripts/configure.sh [check|plan|apply]' >&2; exit 1; }
fail() {
  printf '\nERRO: %s\nComo corrigir: %s\nDepois execute novamente: bash scripts/configure.sh %s\n' "$1" "$2" "$MODE" >&2
  exit 1
}
fail_config() {
  printf '\nERRO: %s em config/lab.env esta invalido.\nFormato esperado: %s\nExemplo: %s\n' "$1" "$2" "$3" >&2
  [[ -z "${4:-}" ]] || printf '%s\n' "$4" >&2
  printf 'Como corrigir: edite config/lab.env (nano config/lab.env) e ajuste o campo %s.\nDepois execute novamente: bash scripts/configure.sh %s\n' "$1" "$MODE" >&2
  exit 1
}
for tool in oci gh jq sha256sum sed; do
  command -v "$tool" >/dev/null || fail "O comando $tool nao foi encontrado neste terminal." "Instale $tool dentro do Linux/WSL e confirme com: command -v $tool. Consulte os pre-requisitos no README."
done
[[ -f config/lab.env ]] || fail 'O arquivo local config/lab.env nao existe.' 'Execute cp config/lab.env.example config/lab.env; depois edite config/lab.env com os dados do ambiente.'
# Arquivo local controlado pelo operador, sem segredos.
# Aceitar arquivos salvos no Windows (CRLF) sem alterar seu conteudo local.
source <(sed 's/\r$//' config/lab.env)
for name in GITHUB_REPOSITORY GITHUB_BRANCH OCI_REGION OCI_COMPARTMENT_OCID OCI_DOMAIN_URL OCI_NAMESPACE OCI_BUCKET OCI_ADMIN_PROFILE OCI_ADMIN_AUTH OCI_APP_NAME OCI_TRUST_NAME OCI_POLICY_NAME OIDC_AUDIENCE OCI_RES_TYPE; do
  [[ -n "${!name:-}" ]] || fail "O campo $name esta vazio ou ausente em config/lab.env." "Edite config/lab.env e preencha $name. Consulte o significado do campo na tabela de configuracao do README."
done
EXAMPLE_FIELDS=()
[[ "$GITHUB_REPOSITORY" != example-owner/example-repo ]] || EXAMPLE_FIELDS+=(GITHUB_REPOSITORY)
[[ "$OCI_COMPARTMENT_OCID" != *SUBSTITUA* ]] || EXAMPLE_FIELDS+=(OCI_COMPARTMENT_OCID)
[[ "$OCI_DOMAIN_URL" != https://idcs-example.identity.oraclecloud.com* ]] || EXAMPLE_FIELDS+=(OCI_DOMAIN_URL)
[[ "$OCI_NAMESPACE" != example_namespace ]] || EXAMPLE_FIELDS+=(OCI_NAMESPACE)
[[ "$OCI_BUCKET" != example-bucket ]] || EXAMPLE_FIELDS+=(OCI_BUCKET)
if (( ${#EXAMPLE_FIELDS[@]} )); then
  fail "Ainda ha valores ficticios nestes campos de config/lab.env: ${EXAMPLE_FIELDS[*]}." 'Edite config/lab.env e substitua os campos listados pelos dados reais do seu laboratorio.'
fi
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$GITHUB_REPOSITORY" != *.git ]] || fail_config GITHUB_REPOSITORY 'DONO/REPOSITORIO, sem URL, espacos, sufixo .git ou barra final' 'GITHUB_REPOSITORY=seu-usuario/oci-wif-lab' 'Nao use https://github.com/seu-usuario/oci-wif-lab nem git@github.com:seu-usuario/oci-wif-lab.git.'
[[ "$GITHUB_BRANCH" =~ ^[A-Za-z0-9_./-]+$ && "$GITHUB_BRANCH" != refs/heads/* ]] || fail_config GITHUB_BRANCH 'nome curto da branch, sem refs/heads/ nem espacos' 'GITHUB_BRANCH=main'
[[ "$OCI_COMPARTMENT_OCID" == ocid1.compartment.* && "$OCI_COMPARTMENT_OCID" != *[[:space:]]* ]] || fail_config OCI_COMPARTMENT_OCID 'OCID do compartment que contem o bucket, iniciado por ocid1.compartment.' 'OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..COLE_O_IDENTIFICADOR_REAL'
for name in OCI_BUCKET OCI_APP_NAME OCI_TRUST_NAME OCI_POLICY_NAME OIDC_AUDIENCE OCI_RES_TYPE; do
  [[ "${!name}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_config "$name" 'neste laboratorio, um nome simples com letras, numeros, ponto, hifen ou sublinhado; sem espacos nem URL' "$name=oci-wif-lab"
done
OCI_DOMAIN_URL=${OCI_DOMAIN_URL%/}
[[ "$OCI_DOMAIN_URL" =~ ^https://[a-zA-Z0-9-]+\.identity\.oraclecloud\.com(:443)?$ ]] || fail_config OCI_DOMAIN_URL 'URL HTTPS do Identity Domain OCI comercial, com porta 443 opcional e sem caminho de API' 'OCI_DOMAIN_URL=https://idcs-SEU-DOMINIO.identity.oraclecloud.com:443' 'Nao use a URL do Console OCI, /admin/v1, /oauth2/v1/token ou uma porta diferente de 443.'
if [[ "$MODE" == check ]]; then
  echo 'Configuracao local valida. Nenhuma chamada OCI ou GitHub foi executada.'
  echo 'Continue com a autenticacao dos CLIs e a preparacao do repositorio no README.'
  exit 0
fi
oci_admin() { command oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --output json "$@"; }
mkdir -p .generated .state
TEMP_DIR=$(mktemp -d /tmp/oci-github-setup.XXXXXX)
cleanup() {
  rm -f -- "$TEMP_DIR/app-response.json"
  rmdir -- "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT
CURRENT_STEP='consultar as contas'
RECOVERY='Confira o acesso dos CLIs e os campos de config/lab.env.'
report_failure() {
  local code=$1
  printf '\nERRO na etapa: %s.\nComo corrigir: %s\n' "$CURRENT_STEP" "$RECOVERY" >&2
  if [[ "$MODE" == apply ]]; then
    printf 'Etapas anteriores podem ter criado recursos. Preserve .state/resources.json para retomar; nao houve rollback automatico.\n' >&2
  else
    printf 'O plan nao solicitou criacao de recursos.\n' >&2
  fi
  printf 'Depois execute novamente: bash scripts/configure.sh %s\n' "$MODE" >&2
  exit "$code"
}
trap 'report_failure "$?"' ERR

echo 'Verificando acesso e descobrindo identificadores...'
CURRENT_STEP='acessar o repositorio GitHub'
RECOVERY='Confira GITHUB_REPOSITORY em config/lab.env, confirme que o repositorio ja existe e execute gh auth status para verificar a conta usada.'
gh api "repos/$GITHUB_REPOSITORY" > .generated/github.json
jq -e '.permissions.admin == true' .generated/github.json >/dev/null || fail 'A conta autenticada no gh nao tem permissao de administrador no repositorio de destino.' 'Execute gh auth status, selecione a conta correta ou solicite acesso administrativo ao repositorio informado em GITHUB_REPOSITORY.'
REPOSITORY_ID=$(jq -er '.id | tostring' .generated/github.json)
CURRENT_STEP='consultar a regiao principal da tenancy OCI'
RECOVERY='Confira OCI_REGION, OCI_ADMIN_PROFILE e OCI_ADMIN_AUTH em config/lab.env. Se a sessao expirou, repita oci session authenticate com a regiao e o profile configurados.'
oci_admin iam region-subscription list --all --region "$OCI_REGION" > .generated/regions.json
IAM_REGION=$(jq -er '.data[] | select(."is-home-region" == true) | ."region-name"' .generated/regions.json)
TENANCY_ID=${OCI_TENANCY_OCID:-$OCI_COMPARTMENT_OCID}
CURRENT_STEP='identificar a tenancy pelo compartment'
RECOVERY='Confira OCI_COMPARTMENT_OCID e o acesso administrativo. Se necessario, preencha OCI_TENANCY_OCID com o campo tenancy do profile OCI CLI.'
for ((depth=0; depth<32; depth++)); do
  [[ "$TENANCY_ID" == ocid1.tenancy.* ]] && break
  TENANCY_ID=$(oci_admin iam compartment get --compartment-id "$TENANCY_ID" --region "$IAM_REGION" --query 'data."compartment-id"' --raw-output)
done
[[ "$TENANCY_ID" == ocid1.tenancy.* ]] || fail 'Nao foi possivel descobrir a tenancy a partir do compartment.' 'Preencha OCI_TENANCY_OCID em config/lab.env com o campo tenancy do profile OCI CLI.'
CURRENT_STEP='localizar o Identity Domain'
RECOVERY='Confira OCI_DOMAIN_URL e as permissoes no dominio. Se ele estiver em outro compartment, preencha OCI_DOMAIN_COMPARTMENT_OCID; alternativamente informe OCI_DOMAIN_OCID.'
if [[ -n "${OCI_DOMAIN_OCID:-}" ]]; then
  oci_admin iam domain get --domain-id "$OCI_DOMAIN_OCID" --region "$IAM_REGION" > .generated/domain.json
  DOMAIN_ID=$(jq -er '.data.id' .generated/domain.json)
  DOMAIN_FOUND_URL=$(jq -er '.data.url' .generated/domain.json)
  [[ "${DOMAIN_FOUND_URL%:443}" == "${OCI_DOMAIN_URL%:443}" ]] || fail 'OCI_DOMAIN_OCID e OCI_DOMAIN_URL identificam dominios diferentes.' 'Confira os detalhes do mesmo Identity Domain e corrija os dois campos em config/lab.env.'
else
  oci_admin iam domain list --compartment-id "${OCI_DOMAIN_COMPARTMENT_OCID:-$TENANCY_ID}" --region "$IAM_REGION" --all > .generated/domains.json
  DOMAIN_ID=$(jq -er --arg url "$OCI_DOMAIN_URL" '[.data[] | select((.url | rtrimstr("/") | rtrimstr(":443")) == ($url | rtrimstr(":443")))] | if length == 1 then .[0].id else error("Informe OCI_DOMAIN_OCID ou OCI_DOMAIN_COMPARTMENT_OCID em config/lab.env") end' .generated/domains.json)
fi
CURRENT_STEP='consultar o bucket de Object Storage'
RECOVERY='Confira OCI_REGION, OCI_NAMESPACE e OCI_BUCKET em config/lab.env. O bucket precisa existir e a conta OCI precisa ter acesso a ele.'
oci_admin os bucket get --namespace-name "$OCI_NAMESPACE" --bucket-name "$OCI_BUCKET" --region "$OCI_REGION" > .generated/bucket.json
[[ "$(jq -er '.data."compartment-id"' .generated/bucket.json)" == "$OCI_COMPARTMENT_OCID" ]] || fail 'O bucket encontrado pertence a outro compartment.' 'Corrija OCI_COMPARTMENT_OCID para o compartment do bucket, ou ajuste OCI_BUCKET, OCI_NAMESPACE e OCI_REGION para selecionar o bucket desejado.'
CURRENT_STEP='gerar os arquivos locais do plano'
RECOVERY='Confira se os modelos config/app.json, config/trust.json e scripts/render.jq existem e se esta pasta permite gravar em .generated e .state.'
WORKFLOW_REF="$GITHUB_REPOSITORY/.github/workflows/oci-wif-integration.yml@refs/heads/$GITHUB_BRANCH"
jq -n --arg repository "$GITHUB_REPOSITORY" --arg repository_id "$REPOSITORY_ID" --arg branch "$GITHUB_BRANCH" --arg domain_url "$OCI_DOMAIN_URL" --arg domain_ocid "$DOMAIN_ID" --arg tenancy_ocid "$TENANCY_ID" --arg compartment_ocid "$OCI_COMPARTMENT_OCID" --arg region "$OCI_REGION" --arg iam_region "$IAM_REGION" --arg namespace "$OCI_NAMESPACE" --arg bucket "$OCI_BUCKET" --arg workflow_ref "$WORKFLOW_REF" --arg audience "$OIDC_AUDIENCE" --arg res_type "$OCI_RES_TYPE" --arg app_name "$OCI_APP_NAME" --arg trust_name "$OCI_TRUST_NAME" --arg policy_name "$OCI_POLICY_NAME" '$ARGS.named' > .generated/context.json
jq --arg name "$OCI_APP_NAME" '.displayName = $name' config/app.json > .generated/app.json
jq --slurpfile c .generated/context.json '.name = $c[0].trust_name | .impersonatingResource = $c[0].res_type | .oauthClients = ["CLIENT_ID_APOS_CRIAR_APP"] | .claimValidations = [{name:"aud",value:$c[0].audience},{name:"repository",value:$c[0].repository},{name:"repository_id",value:$c[0].repository_id},{name:"ref",value:("refs/heads/"+$c[0].branch)},{name:"workflow_ref",value:$c[0].workflow_ref}]' config/trust.json > .generated/trust.json
jq -f scripts/render.jq .generated/context.json | jq -s '.' > .generated/policy-statements.json
jq -r '.[]' .generated/policy-statements.json > .generated/policy.txt

# O plan precisa tambem comprovar acesso administrativo ao endpoint do dominio.
CURRENT_STEP='consultar as trusts do Identity Domain'
RECOVERY='Confira OCI_DOMAIN_URL, a sessao do profile OCI e as permissoes administrativas no Identity Domain.'
oci_admin identity-domains identity-propagation-trust list --endpoint "$OCI_DOMAIN_URL" --filter 'issuer eq "https://token.actions.githubusercontent.com"' --all > .generated/existing-trusts.json
STATE=.state/resources.json
[[ -f "$STATE" ]] || printf '{}\n' > "$STATE"
if jq -e '.cleanup_started == true or .cleanup_complete == true' "$STATE" >/dev/null; then
  echo 'Este estado esta em limpeza ou ja foi limpo. Conclua cleanup.sh apply e use outra copia para um novo lab.' >&2
  exit 1
fi
FINGERPRINT=$(jq -Sc . .generated/context.json | sha256sum | cut -d ' ' -f 1)
PREVIOUS=$(jq -r '.context_sha256 // empty' "$STATE")
[[ -z "$PREVIOUS" || "$PREVIOUS" == "$FINGERPRINT" ]] || { echo 'O estado pertence a outra configuracao. Use outro clone/pasta para outro ambiente.' >&2; exit 1; }
KNOWN_TRUST=$(jq -r '.trust_id // empty' "$STATE")
jq -e --arg known "$KNOWN_TRUST" '[(.data.resources // .data.Resources // [])[] | select(.id != $known)] | length == 0' .generated/existing-trusts.json >/dev/null || { echo 'Ja existe outra trust para o emissor GitHub neste dominio. Revise-a antes de continuar; o script nao altera trusts existentes.' >&2; exit 1; }
if [[ "$MODE" == plan ]]; then
  echo 'Plan concluido. Revise .generated/app.json, trust.json e policy.txt.'
  echo 'Para criar o app, a trust, a policy e cadastrar o segredo no GitHub:'
  echo 'bash scripts/configure.sh apply'
  exit 0
fi
save_state() {
  jq --arg key "$1" --arg value "$2" '.[$key] = $value' "$STATE" > .state/resources.tmp
  mv -- .state/resources.tmp "$STATE"
}
save_state context_sha256 "$FINGERPRINT"
APP_ID=$(jq -r '.app_id // empty' "$STATE")
if [[ -z "$APP_ID" ]]; then
  CURRENT_STEP='criar o aplicativo OAuth'
  RECOVERY='Confira as permissoes no dominio e se OCI_APP_NAME ja esta em uso. Se a criacao ja foi registrada em .state, preserve esse arquivo para retomar.'
  echo 'Criando aplicativo OAuth sem App Roles...'
  oci_admin identity-domains app create --endpoint "$OCI_DOMAIN_URL" --from-json file://.generated/app.json > "$TEMP_DIR/app-response.json"
  APP_ID=$(jq -er '.data.id' "$TEMP_DIR/app-response.json")
  save_state app_id "$APP_ID"
else
  oci_admin identity-domains app get --endpoint "$OCI_DOMAIN_URL" --app-id "$APP_ID" > "$TEMP_DIR/app-response.json"
fi
CLIENT_ID=$(jq -er '.data.name' "$TEMP_DIR/app-response.json")
save_state client_id "$CLIENT_ID"
CURRENT_STEP='ativar o aplicativo OAuth'
RECOVERY='Confira o app_id em .state/resources.json e a permissao para administrar esse aplicativo no Identity Domain.'
oci_admin identity-domains app-status-changer put --endpoint "$OCI_DOMAIN_URL" --app-status-changer-id "$APP_ID" --active true --schemas '["urn:ietf:params:scim:schemas:oracle:idcs:AppStatusChanger"]' --force >/dev/null
jq --arg client "$CLIENT_ID" '.oauthClients = [$client]' .generated/trust.json > .generated/trust.tmp
mv -- .generated/trust.tmp .generated/trust.json
TRUST_ID=$(jq -r '.trust_id // empty' "$STATE")
if [[ -z "$TRUST_ID" ]]; then
  CURRENT_STEP='criar a Identity Propagation Trust'
  RECOVERY='Revise .generated/trust.json, o app ativo e as permissoes no dominio. Confira se ja existe uma trust para o issuer do GitHub.'
  echo 'Criando Identity Propagation Trust...'
  oci_admin identity-domains identity-propagation-trust create --endpoint "$OCI_DOMAIN_URL" --from-json file://.generated/trust.json > .generated/trust-response.json
  TRUST_ID=$(jq -er '.data.id' .generated/trust-response.json)
  save_state trust_id "$TRUST_ID"
fi
POLICY_ID=$(jq -r '.policy_id // empty' "$STATE")
if [[ -z "$POLICY_ID" ]]; then
  CURRENT_STEP='criar a policy IAM'
  RECOVERY='Revise .generated/policy.txt, OCI_POLICY_NAME e as permissoes para criar policies no compartment. Confira se o nome da policy ja existe.'
  echo 'Criando policy restrita ao bucket...'
  oci_admin iam policy create --region "$IAM_REGION" --compartment-id "$OCI_COMPARTMENT_OCID" --name "$OCI_POLICY_NAME" --description 'GitHub OIDC lab: inspect objects in one bucket' --statements file://.generated/policy-statements.json > .generated/policy-response.json
  POLICY_ID=$(jq -er '.data.id' .generated/policy-response.json)
  save_state policy_id "$POLICY_ID"
fi

echo 'Configurando variaveis e segredo no GitHub...'
CURRENT_STEP='cadastrar variaveis e segredo no GitHub'
RECOVERY='Execute gh auth status e confira acesso administrativo ao repositorio. Preserve .state/resources.json; repita apply para retomar sem recriar os recursos ja registrados.'
save_state github_configuration_started true
gh variable set OCI_CLIENT_ID --repo "$GITHUB_REPOSITORY" --body "$CLIENT_ID"
while IFS=$'\t' read -r key value; do
  gh variable set "$key" --repo "$GITHUB_REPOSITORY" --body "$value"
done < <(jq -r '{OCI_REGION:.region,OCI_DOMAIN_URL:.domain_url,OCI_NAMESPACE:.namespace,OCI_BUCKET:.bucket,EXPECTED_REPOSITORY:.repository,EXPECTED_BRANCH:.branch,OIDC_AUDIENCE:.audience,OCI_RES_TYPE:.res_type} | to_entries[] | [.key,.value] | @tsv' .generated/context.json)
# Algumas versoes do dominio so retornam clientSecret quando solicitado.
if ! jq -e '(.data["client-secret"] // .data.clientSecret // "") | type == "string" and length > 8 and (contains("*") | not)' "$TEMP_DIR/app-response.json" >/dev/null; then
  oci_admin identity-domains app get --endpoint "$OCI_DOMAIN_URL" --app-id "$APP_ID" --attributes id,name,clientSecret > "$TEMP_DIR/app-response.json"
fi
jq -e '(.data["client-secret"] // .data.clientSecret // "") | type == "string" and length > 8 and (contains("*") | not)' "$TEMP_DIR/app-response.json" >/dev/null || { echo 'O dominio nao retornou o Client Secret. Pare e confira permissao e API do dominio; nenhum segredo foi inventado ou registrado no GitHub.' >&2; exit 1; }
jq -erj '.data["client-secret"] // .data.clientSecret' "$TEMP_DIR/app-response.json" | gh secret set OCI_CLIENT_SECRET --repo "$GITHUB_REPOSITORY"
echo 'Configuracao concluida. IDs publicos: .state/resources.json.'
echo 'Publique os arquivos na branch configurada e execute o workflow conforme o README.'
