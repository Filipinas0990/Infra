#!/usr/bin/env bash
# Prepara a WuzAPI no namespace DEV (rodar UMA vez, da máquina do Filipe).
#  1. cria o banco wuzapi_dev + usuário no db-eu
#  2. cria o Secret wuzapi-secrets (dev)
#  3. acrescenta as chaves WUZAPI_* ao Secret api-04-secrets (dev), sem mexer nas outras
#  4. aplica o Deployment e o Service da WuzAPI
# Nenhuma senha ou token é impresso na tela nem passa na linha de comando.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kelmor-hetzner.yaml}"
NS=dev
DB_NAME=wuzapi_dev
DB_USER=wuzapi_dev
DB_SSH="ssh -i $HOME/.ssh/banco-de-dados root@2.29.156.86"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "Cluster: $(kubectl config current-context) · namespace: $NS"
kubectl get ns "$NS" >/dev/null

if kubectl get secret wuzapi-secrets -n "$NS" >/dev/null 2>&1; then
    echo "O Secret wuzapi-secrets já existe em $NS — nada a fazer (apague-o antes se quiser recriar)." >&2
    exit 1
fi

# Segredos gerados aqui e só guardados nos Secrets
DB_PASSWORD="$(openssl rand -hex 24)"
WUZAPI_ADMIN_TOKEN="$(openssl rand -hex 24)"
WUZAPI_GLOBAL_ENCRYPTION_KEY="$(openssl rand -hex 16)"   # 32 caracteres = 32 bytes (AES-256)
WUZAPI_SECRET="$(openssl rand -hex 32)"                  # deriva token e HMAC de cada conexão

echo "1/4 Criando banco $DB_NAME no db-eu..."
# A senha vai pelo stdin do ssh (não aparece em argv nem no histórico)
$DB_SSH 'cd /root/kelmor-data && set -a && . ./.env && set +a && docker exec -i kelmor-postgres psql -v ON_ERROR_STOP=1 -U "$PG_ADMIN_USER" -d postgres' <<SQL
CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD' CONNECTION LIMIT 20;
CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8';
REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;
SQL

echo "2/4 Criando Secret wuzapi-secrets..."
kubectl create secret generic wuzapi-secrets -n "$NS" --from-env-file=<(printf '%s\n' \
    "WUZAPI_ADMIN_TOKEN=$WUZAPI_ADMIN_TOKEN" \
    "WUZAPI_GLOBAL_ENCRYPTION_KEY=$WUZAPI_GLOBAL_ENCRYPTION_KEY" \
    "DB_USER=$DB_USER" \
    "DB_PASSWORD=$DB_PASSWORD" \
    "DB_NAME=$DB_NAME") >/dev/null

echo "3/4 Acrescentando WUZAPI_* ao api-04-secrets (as chaves existentes ficam como estão)..."
kubectl patch secret api-04-secrets -n "$NS" --type merge --patch-file <(printf '{"stringData":{%s}}' \
    "\"WUZAPI_URL\":\"http://wuzapi:8080\",\"WUZAPI_ADMIN_TOKEN\":\"$WUZAPI_ADMIN_TOKEN\",\"WUZAPI_SECRET\":\"$WUZAPI_SECRET\",\"WUZAPI_WEBHOOK_BASE_URL\":\"http://api-04\"") >/dev/null

echo "4/4 Aplicando Deployment e Service..."
kubectl apply -f "$HERE/wuzapi-deployment.yaml" -f "$HERE/wuzapi-service.yaml"
kubectl rollout status deploy/wuzapi -n "$NS" --timeout=180s

echo
echo "Pronto. A api-04 do dev só passa a usar a WuzAPI quando subir uma imagem com o código feat/wuzapi"
echo "(o deploy reinicia o pod e ele lê as chaves novas)."
