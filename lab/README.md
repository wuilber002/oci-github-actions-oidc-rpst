# Configurar o laboratório GitHub Actions com OCI

Este roteiro configura um repositório próprio para acessar OCI Object Storage por GitHub Actions. O workflow troca o token OIDC do GitHub por um RPST de 20 minutos e lista até 10 objetos de um bucket privado.

O fluxo usa `client_id` e `client_secret` de um aplicativo OAuth. O segredo fica em GitHub Actions Secrets. Uma chave RSA temporária é gerada em memória por execução, e o aplicativo do workflow não recebe papel administrativo. [Fluxo documentado pela Oracle](https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/token_exchange_grant_type_workload_id-federation.htm)

Comece **na pasta copiada do laboratório**. Na etapa de preparar o repositório, escolha entre criar um novo ou usar um existente. A partir daí, execute os comandos na raiz do repositório de destino. A pasta `.github/workflows/` precisa ficar nessa raiz para que o GitHub reconheça o workflow.

Veja o [fluxo de autenticação em três etapas no README principal](https://github.com/wuilber002/oci-github-actions-oidc-rpst#como-funciona-a-autenticação).

## Pré requisitos

- Bash em Linux ou WSL; Git, OCI CLI (`oci`), GitHub CLI (`gh`), `jq`, `sed` e `sha256sum` instalados.
- Git configurado com nome e e-mail para criar commits.
- Conta GitHub com permissão para criar e administrar um repositório.
- Conta OCI com permissão administrativa no Identity Domain e para criar policies no compartment escolhido.
- Um compartment e um bucket privado existentes na região escolhida.

```bash
git --version
oci --version
gh --version
jq --version
```

O OCI CLI precisa oferecer as opções `--claim-validations` e `--claim-propagations` no comando abaixo:

```bash
oci identity-domains identity-propagation-trust create --help
```

## Preencher a configuração local

```bash
cp config/lab.env.example config/lab.env
nano config/lab.env
```

Substitua os exemplos nestes campos:

| Campo | O que informar |
| --- | --- |
| `GITHUB_REPOSITORY` | Seu usuário ou organização e o repositório de destino, novo ou existente, como `seu-usuario/oci-wif-lab`; sem URL. |
| `GITHUB_BRANCH` | Branch padrão do repositório de destino; normalmente `main`. |
| `OCI_REGION` | Região onde está o bucket. |
| `OCI_COMPARTMENT_OCID` | OCID do compartment que contém o bucket. |
| `OCI_DOMAIN_URL` | URL HTTPS do Identity Domain, como `https://idcs-example.identity.oraclecloud.com`. |
| `OCI_NAMESPACE` | Namespace de Object Storage da tenancy. |
| `OCI_BUCKET` | Nome do bucket privado existente. |

Os nomes do app, da trust e da policy podem ser mantidos. O script descobre a tenancy, a home region do IAM, o OCID do domínio e o ID do repositório. Se o domínio estiver em outro compartment, informe `OCI_DOMAIN_COMPARTMENT_OCID`; também é possível informar diretamente `OCI_DOMAIN_OCID`.

Mantenha os dados reais somente em `config/lab.env`. Não preencha nem publique `lab.env.example` com dados do ambiente. O script aceita arquivos com quebras de linha Linux ou Windows e bloqueia os valores fictícios.

Valide os formatos antes de autenticar ou criar recursos:

```bash
bash scripts/configure.sh check
```

O `check` verifica os comandos instalados e os campos locais, sem acessar OCI ou GitHub. Ele não confirma a existência dos recursos nem as permissões; essas verificações são feitas pelo `plan`, depois que o repositório existir.

## Autenticar os CLIs

```bash
source <(sed 's/\r$//' config/lab.env)

# HTTPS permite usar o login do gh também para git push.
gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow
gh auth setup-git --hostname github.com
gh auth status

oci session authenticate --region "$OCI_REGION" --profile-name "$OCI_ADMIN_PROFILE"
oci session validate --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH"
```

Conclua os logins solicitados. A sessão administrativa OCI é local e não é enviada ao GitHub. Se os CLIs já estiverem autenticados nas contas corretas, não é necessário refazer os logins. [Sessões do OCI CLI](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/session/authenticate.html)

Para consultar dados OCI, use seu OCID de tenancy, disponível no campo `tenancy` do profile criado em `~/.oci/config`:

```bash
OCI_TENANCY_OCID=SUBSTITUA_PELO_OCID_DA_TENANCY
IAM_REGION=$(oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" \
  --region "$OCI_REGION" iam region-subscription list \
  --query 'data[?"is-home-region" == `true`]."region-name" | [0]' --raw-output)
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$IAM_REGION" \
  iam domain list --compartment-id "$OCI_TENANCY_OCID" --all \
  --query 'data[].{name:"display-name",ocid:id,url:url}'
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$OCI_REGION" \
  os ns get --query data --raw-output
```

## Preparar o repositório do laboratório

Escolha **apenas uma** das opções abaixo. O repositório informado em `GITHUB_REPOSITORY` será o destino das variáveis, do secret e do workflow do lab.

### Criar um repositório novo

Use um nome ainda não existente em `GITHUB_REPOSITORY`. Na pasta copiada do laboratório:

```bash
bash scripts/configure.sh check
source <(sed 's/\r$//' config/lab.env)
git init --initial-branch "$GITHUB_BRANCH"
git check-ignore config/lab.env
git add README.md .gitignore .gitattributes .github config scripts requirements.txt
git diff --cached --stat
git commit -m "Add OCI WIF laboratory"
gh repo create "$GITHUB_REPOSITORY" --private --source=. --remote=origin --push
```

O repositório do laboratório é criado como privado; troque `--private` por `--public` se desejar publicá-lo. A cópia contém somente os arquivos necessários ao lab. O workflow é manual e não é executado pelo push. [Criar repositórios com gh](https://cli.github.com/manual/gh_repo_create)

Use `GITHUB_REPOSITORY=seu-usuario/oci-wif-lab`, sem `https://` e sem `.git`. Esse formato é aceito por `gh repo create`, `gh repo clone` e pelas opções `--repo` dos outros comandos deste guia. O protocolo de transporte é definido separadamente pelo login/configuração do `gh`.

### Usar um repositório já criado

Esta opção serve para um repositório remoto vazio ou com commits. Em vez de criar outro histórico e tentar juntá-lo ao remoto, clone o destino e copie os arquivos do lab para esse clone:

```bash
# Execute ainda na pasta copiada do lab, com lab.env preenchido.
bash scripts/configure.sh check
source <(sed 's/\r$//' config/lab.env)
LAB_SOURCE_DIR="$PWD"
LAB_TARGET_DIR="$(dirname "$LAB_SOURCE_DIR")/oci-wif-existing"

gh repo clone "$GITHUB_REPOSITORY" "$LAB_TARGET_DIR"
bash "$LAB_SOURCE_DIR/scripts/copy-to-repo.sh" "$LAB_TARGET_DIR"
cd "$LAB_TARGET_DIR"

# Se o remoto estiver vazio, definir o nome da primeira branch.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git symbolic-ref HEAD "refs/heads/$GITHUB_BRANCH"
fi
git branch --show-current
nano config/lab.env
source <(sed 's/\r$//' config/lab.env)
```

Use um diretório de destino novo para o clone. Se o repositório já contém commits, o clone seleciona sua branch padrão; ajuste `GITHUB_BRANCH` no arquivo local para o nome mostrado por `git branch --show-current`. Mantenha o workflow na branch padrão para permitir a execução manual.

O script preserva o README existente e copia o guia como `OCI-WIF-LAB.md`. Ele acrescenta as regras do lab a `.gitignore` e regras de LF específicas aos arquivos copiados em `.gitattributes`. Não copia `.git`, `.state` ou `.generated`. Se um arquivo do lab já existir no destino, como `requirements.txt`, o script para antes de copiar; compare e integre manualmente ou use um repositório dedicado ao lab.

Depois de conferir a cópia e a branch:

```bash
git check-ignore config/lab.env
git status --short
git add OCI-WIF-LAB.md .gitignore .gitattributes \
  .github/workflows/oci-wif-integration.yml \
  config/app.json config/trust.json config/lab.env.example \
  scripts/configure.sh scripts/cleanup.sh scripts/copy-to-repo.sh \
  scripts/render.jq scripts/validate_oci.py requirements.txt
git diff --cached --stat
git commit -m "Add OCI WIF laboratory"
git push -u origin "$GITHUB_BRANCH"
```

Não é necessário executar `gh repo create` nessa opção. O histórico remoto é preservado e o push não usa `--force`. Se a branch exigir revisão por pull request, siga esse fluxo e conclua a inclusão do workflow na branch padrão antes do teste. [Clonar com gh](https://cli.github.com/manual/gh_repo_clone), [execução manual de workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

Continue as próximas etapas **na pasta de destino**, onde estão o `lab.env` e os arquivos que acabou de publicar.

## Revisar e configurar a integração

```bash
bash scripts/configure.sh plan
cat .generated/app.json
cat .generated/trust.json
cat .generated/policy.txt
```

O `plan` consulta OCI e GitHub e gera arquivos locais. Não cria recursos nem configura secrets. O marcador em `oauthClients` será substituído pelo Client ID no `apply`.

A trust exige audience, repositório, ID do repositório, branch e caminho do workflow exatos. A policy permite apenas listar objetos do bucket informado, condicionada ao domínio e às claims propagadas. A policy é criada na home region do IAM, que pode diferir da região do bucket.

Depois de revisar:

```bash
bash scripts/configure.sh apply
```

O `apply` repete as verificações e usa o `lab.env` atual. Ele:

1. Cria e ativa um aplicativo OAuth com grant `client_credentials`, sem App Roles.
2. Cria a Identity Propagation Trust para o GitHub.
3. Cria a policy restrita ao bucket.
4. Cadastra os parâmetros como variáveis e o `OCI_CLIENT_SECRET` como secret no repositório de destino.

Variáveis e secrets com os mesmos nomes são atualizados. O script não cria VM, não altera objetos do bucket e não inicia o workflow. O segredo retorna da API para um arquivo temporário privado e é removido ao terminar; não execute com `bash -x` nem `oci --debug`. [Criar aplicativo pelo CLI](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/identity-domains/app/create.html), [cadastrar secrets com gh](https://cli.github.com/manual/gh_secret_set)

```bash
cat .state/resources.json
gh variable list --repo "$GITHUB_REPOSITORY"
gh secret list --repo "$GITHUB_REPOSITORY"
```

Os IDs ficam em `.state/resources.json`. Se uma etapa falhar, corrija a causa e repita `apply` para retomar. Preserve o estado: o script não faz rollback automático nem reconcilia alterações manuais. Use outra cópia para outro ambiente. Se já houver uma trust para o issuer do GitHub nesse domínio, o script interrompe para evitar alterar uma integração existente.

## Executar o teste no GitHub

```bash
gh workflow run oci-wif-integration.yml --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_BRANCH"
gh run list --repo "$GITHUB_REPOSITORY" --workflow oci-wif-integration.yml --limit 5
```

Copie o ID da execução desejada:

```bash
RUN_ID=SUBSTITUA_PELO_ID_DA_EXECUCAO
gh run watch "$RUN_ID" --repo "$GITHUB_REPOSITORY" --exit-status
gh run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log |
  sed -nE 's/^.*(Troca JWT por RPST concluida\.|Acesso OCI validado: ListObjects retornou HTTP [0-9]+|Objetos nesta pagina: [0-9]+)$/\1/p'
```

O comando acima mostra apenas as três mensagens de resultado, sem os prefixos de etapa e horário. Resultado esperado:

```text
Troca JWT por RPST concluida.
Acesso OCI validado: ListObjects retornou HTTP 200
Objetos nesta pagina: 0
```

A quantidade depende do bucket; zero objetos também é sucesso. O workflow usa `ubuntu-24.04` e não publica chaves nem tokens como artifacts.

O filtro mostra somente as mensagens produzidas; uma falha pode deixar a saída incompleta ou vazia. Confirme o sucesso pelo `gh run watch --exit-status` acima. Para investigar uma falha, mostre somente os logs das etapas que falharam:

```bash
gh run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log-failed
```

## Resolver falhas comuns

| Falha | Ação |
| --- | --- |
| `GITHUB_REPOSITORY` inválido | Edite `config/lab.env`: use `GITHUB_REPOSITORY=seu-usuario/oci-wif-lab`, sem `https://github.com/`, `git@github.com:`, `.git`, espaços ou barra final. Repita o mesmo comando `plan` ou `apply`. |
| Valor fictício ou campo vazio | A mensagem lista os campos que precisam ser preenchidos em `config/lab.env`. Edite somente o arquivo local, sem alterar o exemplo público. |
| `OCI_DOMAIN_URL` inválida | Use a URL HTTPS do Identity Domain, com porta `443` opcional, sem caminhos de API e sem usar o endereço do Console OCI. |
| Sessão OCI expirada | Repita `oci session authenticate` com o mesmo profile. |
| Acesso negado no plan | Confira a conta do gh e as permissões do administrador OCI no domínio e no compartment. |
| Domínio não encontrado | Informe `OCI_DOMAIN_OCID` ou `OCI_DOMAIN_COMPARTMENT_OCID`. |
| Nome ou trust já existente | Revise o recurso existente; o script não o substitui automaticamente. |
| Segredo não retornado | Confira a permissão e a API do domínio; o script para antes de cadastrar um valor inválido. |
| Troca por RPST retorna 400 ou 401 | Confira Client ID/Secret, app e trust ativos, audience, branch e caminho do workflow. |
| ListObjects retorna 403 ou 404 | Confira policy, domínio, bucket e namespace; aguarde a propagação do IAM e repita o teste. |
| Workflow não encontrado | Confirme que o push publicou `.github/workflows/oci-wif-integration.yml` na branch padrão do repositório de destino. |

Mantenha o caminho e o nome do workflow: eles fazem parte da trust. O bloqueio local de uma branch diferente não comprova a aplicação das regras IAM.

## Remover e limpar o laboratório

Execute a limpeza na mesma pasta usada pelo `apply`, com `config/lab.env`, `.state/` e `.generated/` preservados. O script confere o contexto e os nomes dos recursos antes de remover os IDs registrados. Renove a sessão OCI se ela tiver expirado.

### Revisar o que será removido

```bash
bash scripts/cleanup.sh plan
```

O plano mostra a conta GitHub de destino, o domínio e os IDs envolvidos, sem excluir recursos. Revise também `.generated/cleanup-plan.json`.

### Remover a integração OCI e GitHub

```bash
bash scripts/cleanup.sh apply
```

O comando executa a limpeza nesta ordem:

1. Desabilita o workflow do laboratório, se ele estiver publicado.
2. Desativa o aplicativo OAuth para bloquear novas trocas de token.
3. Exclui a policy IAM criada pelo lab.
4. Exclui a Identity Propagation Trust criada pelo lab.
5. Exclui o aplicativo OAuth.
6. Remove o secret `OCI_CLIENT_SECRET` e as nove variáveis cadastradas pelo procedimento no GitHub.

As variáveis removidas são `OCI_CLIENT_ID`, `OCI_REGION`, `OCI_DOMAIN_URL`, `OCI_NAMESPACE`, `OCI_BUCKET`, `EXPECTED_REPOSITORY`, `EXPECTED_BRANCH`, `OIDC_AUDIENCE` e `OCI_RES_TYPE`. O script remove esses nomes mesmo se já existiam antes do lab; valores anteriores não são restaurados. Ele só limpa as variáveis e o secret quando o estado registra o início da configuração GitHub.

O bucket, seus objetos, o compartment, o Identity Domain e o repositório GitHub permanecem. RPSTs já emitidos expiram naturalmente; a exclusão da policy retira a autorização concedida por ela após a propagação do IAM. Outras policies eventualmente existentes continuam sendo avaliadas normalmente.

Os comandos de exclusão do OCI usados pelo script são [app delete](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/identity-domains/app/delete.html), [identity propagation trust delete](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/identity-domains/identity-propagation-trust/delete.html) e `iam policy delete`.

Se uma etapa falhar, corrija a causa e repita `cleanup.sh apply`. O progresso fica em `.state/cleanup.json` para retomar os passos pendentes. Depois da limpeza, o estado fica marcado como concluído: use outra cópia limpa para um novo laboratório.

### Excluir também o repositório de teste

Opcional: execute somente para o repositório próprio criado durante o laboratório, depois de concluir a limpeza da integração. Isso exclui o repositório remoto, incluindo seus arquivos, histórico e execuções; a cópia local permanece.

```bash
source <(sed 's/\r$//' config/lab.env)
printf 'Repositorio de TESTE que sera excluido: %s\n' "$GITHUB_REPOSITORY"
gh auth refresh --hostname github.com --scopes delete_repo
gh repo delete "$GITHUB_REPOSITORY"
```

O CLI pede a confirmação da exclusão. Não use o repositório público de procedimentos como destino dessa operação. [Excluir um repositório com gh](https://cli.github.com/manual/gh_repo_delete)

### Excluir bucket e compartment dedicados ao teste

O procedimento usa recursos OCI existentes e não os exclui automaticamente. Execute os comandos abaixo apenas se o bucket e o compartment foram reservados exclusivamente para esse laboratório e não serão mais usados.

Primeiro, consulte o bucket e seus objetos:

```bash
source <(sed 's/\r$//' config/lab.env)
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$OCI_REGION" \
  os bucket get --namespace-name "$OCI_NAMESPACE" --bucket-name "$OCI_BUCKET"
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$OCI_REGION" \
  os object list --namespace-name "$OCI_NAMESPACE" --bucket-name "$OCI_BUCKET" --all
```

Para excluir o bucket vazio:

```bash
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$OCI_REGION" \
  os bucket delete --namespace-name "$OCI_NAMESPACE" --bucket-name "$OCI_BUCKET"
```

O comando acima não usa `--empty`: se houver conteúdo ou outras dependências, a exclusão falha em vez de removê-los automaticamente. [Comportamento de bucket delete](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/os/bucket/delete.html)

Depois de confirmar que o compartment não contém outros recursos nem subcompartments, exclua-o:

```bash
IAM_REGION=$(jq -r '.iam_region' .generated/context.json)
oci --profile "$OCI_ADMIN_PROFILE" --auth "$OCI_ADMIN_AUTH" --region "$IAM_REGION" \
  iam compartment delete --compartment-id "$OCI_COMPARTMENT_OCID"
```

Não é necessário excluir o Identity Domain para remover este laboratório.

### Encerrar a sessão local e restaurar o exemplo

Ao terminar todas as operações que usam o OCI CLI:

```bash
oci session terminate --profile "$OCI_ADMIN_PROFILE"
cp config/lab.env.example config/lab.env
```

O primeiro comando remove o profile da sessão OCI e seus arquivos de chave referenciados; use-o somente para o profile administrativo dedicado criado neste roteiro. O segundo restaura os valores fictícios do arquivo local. Os arquivos de estado são mantidos para consulta e não são publicados pelo Git. [Encerrar sessão OCI CLI](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/session/terminate.html)
