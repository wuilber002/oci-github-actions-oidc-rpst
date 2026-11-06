#!/usr/bin/env bash
# Copiar somente o lab para a raiz de um clone existente, sem alterar o historico.
set -euo pipefail
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $# == 1 && -d "$1" ]] || { echo 'Uso: bash scripts/copy-to-repo.sh /caminho/do/clone-existente' >&2; exit 1; }
TARGET=$(cd -- "$1" && pwd -P)
[[ "$SOURCE" != "$TARGET" ]] || { echo 'A origem e o destino devem ser pastas diferentes.' >&2; exit 1; }
GIT_ROOT=$(git -C "$TARGET" rev-parse --show-toplevel)
[[ "$(cd -- "$GIT_ROOT" && pwd -P)" == "$TARGET" ]] || { echo 'O destino deve ser a raiz do repositorio Git.' >&2; exit 1; }
[[ -z "$(git -C "$TARGET" status --porcelain)" ]] || { echo 'O clone de destino tem alteracoes locais. Revise-as antes de copiar o lab.' >&2; exit 1; }
FILES=(
  .github/workflows/oci-wif-integration.yml
  config/app.json config/trust.json config/lab.env.example
  scripts/configure.sh scripts/cleanup.sh scripts/copy-to-repo.sh
  scripts/render.jq scripts/validate_oci.py requirements.txt
)
DESTINATIONS=("${FILES[@]}" OCI-WIF-LAB.md)
[[ ! -f "$SOURCE/config/lab.env" ]] || DESTINATIONS+=(config/lab.env)
for parent in .github .github/workflows config scripts; do
  [[ ! -L "$TARGET/$parent" ]] || { echo "Destino com link simbolico: $parent. Revise manualmente." >&2; exit 1; }
  [[ ! -e "$TARGET/$parent" || -d "$TARGET/$parent" ]] || { echo "Destino nao e um diretorio: $parent" >&2; exit 1; }
done
for name in "${DESTINATIONS[@]}"; do
  [[ ! -e "$TARGET/$name" && ! -L "$TARGET/$name" ]] || { echo "Arquivo ja existe: $name. Nenhum arquivo foi copiado; use um repo dedicado ou compare e integre manualmente." >&2; exit 1; }
done
for name in .gitignore .gitattributes; do
  [[ ! -L "$TARGET/$name" && ( ! -e "$TARGET/$name" || -f "$TARGET/$name" ) ]] || { echo "Revise $name no destino." >&2; exit 1; }
done
mkdir -p "$TARGET/.github/workflows" "$TARGET/config" "$TARGET/scripts"
for name in "${FILES[@]}"; do
  cp -- "$SOURCE/$name" "$TARGET/$name"
done
cp -- "$SOURCE/README.md" "$TARGET/OCI-WIF-LAB.md"
printf '\n# OCI WIF laboratory\n' >> "$TARGET/.gitignore"
cat -- "$SOURCE/.gitignore" >> "$TARGET/.gitignore"
printf '\n# OCI WIF laboratory\n' >> "$TARGET/.gitattributes"
for name in "${DESTINATIONS[@]}"; do
  printf '%s text eol=lf\n' "$name" >> "$TARGET/.gitattributes"
done
if [[ -f "$SOURCE/config/lab.env" ]]; then
  cp -- "$SOURCE/config/lab.env" "$TARGET/config/lab.env"
fi
echo 'Lab copiado. README, historico e arquivos anteriores preservados.'
echo 'Revise o diff, confira GITHUB_BRANCH em config/lab.env e continue na pasta de destino.'
