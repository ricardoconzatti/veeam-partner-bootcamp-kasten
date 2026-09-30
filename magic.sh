#!/usr/bin/env bash
#
# ==============================================================================
#  Laboratório Veeam Kasten com K3s + Longhorn
# ==============================================================================
#  Instala, em uma VM Ubuntu 24.04 limpa, um cluster Kubernetes de um nó com
#  K3s, Longhorn como storage e o Veeam Kasten pronto para uso.
#
#  Uso:   sudo bash install-kasten-lab.sh
#
#  AMBIENTE DE LABORATÓRIO. As escolhas aqui (nó único, uma réplica, interfaces
#  sem autenticação) existem para simplificar os testes e não devem ser
#  reproduzidas em produção.
# ==============================================================================

set -euo pipefail

# ==============================================================================
#  VERSÕES — altere aqui para atualizar os componentes
# ==============================================================================
K3S_VERSION="v1.33.11+k3s1"
LONGHORN_VERSION="1.9.2"
SNAPSHOTTER_VERSION="v8.2.0"
KASTEN_VERSION="9.0.6"

# ==============================================================================
#  NOMES E CONFIGURAÇÕES
# ==============================================================================
# Namespaces e releases Helm
LONGHORN_NAMESPACE="longhorn-system"
LONGHORN_RELEASE="longhorn"
KASTEN_NAMESPACE="kasten-io"
KASTEN_RELEASE="k10"

# Storage
STORAGE_CLASS="longhorn-single-replica"   # StorageClass padrão do cluster
SNAPSHOT_CLASS="longhorn-snapshot"        # VolumeSnapshotClass usada pelo Kasten
REPLICA_COUNT="1"                         # réplicas por volume (1 = nó único)

# Rede / acesso às interfaces
INGRESS_CLASS="traefik"                   # controladora que vem com o K3s
INGRESS_HOST=""                           # vazio = acesso pelo IP da VM.
                                          # Preencha (ex: "lab.local") para usar
                                          # nome DNS; exige entrada no /etc/hosts
                                          # da sua estação.
KASTEN_URL_PATH="k10"                     # Kasten em http://IP/k10/
LONGHORN_INGRESS_NAME="longhorn-ingress"
KASTEN_INGRESS_NAME="kasten-ingress"

# Dimensionamento do Kasten (reduzido para caber em VM pequena)
KASTEN_PV_SIZE="8Gi"
KASTEN_PROMETHEUS_SIZE="4Gi"
KASTEN_EXECUTOR_REPLICAS="1"

# Repositórios Helm
LONGHORN_REPO_URL="https://charts.longhorn.io"
KASTEN_REPO_URL="https://charts.kasten.io/"

# Tempo máximo de espera por cada instalação Helm
HELM_TIMEOUT="20m"

# "true" roda apt upgrade no início (mais seguro, porém mais demorado)
APT_UPGRADE="true"

# Requisitos mínimos recomendados (apenas aviso, não bloqueia)
MIN_CPUS=2
MIN_RAM_GB=6
MIN_DISK_GB=40

# ==============================================================================
#  A partir daqui não é necessário alterar nada
# ==============================================================================

readonly KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
readonly SNAPSHOTTER_RAW="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter"
KUBECTL="k3s kubectl"
TOTAL_STEPS=9
CURRENT_STEP=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

step()  { CURRENT_STEP=$((CURRENT_STEP + 1))
          printf '\n%s[%d/%d] %s%s\n' "$C_BOLD$C_CYAN" "$CURRENT_STEP" "$TOTAL_STEPS" "$1" "$C_RESET"; }
info()  { printf '      %s\n' "$1"; }
ok()    { printf '      %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()  { printf '      %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
die()   { printf '\n%sERRO:%s %s\n\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2; exit 1; }

# ------------------------------------------------------------------------------
#  1. Verificações iniciais
# ------------------------------------------------------------------------------
precheck() {
  step "Verificando o ambiente"

  [[ $EUID -eq 0 ]] || die "Execute como root:  sudo bash $0"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "Distribuição detectada: ${PRETTY_NAME:-desconhecida}. O script foi testado no Ubuntu 24.04."
    else
      ok "Sistema operacional: $PRETTY_NAME"
    fi
  fi

  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) ok "Arquitetura: $arch" ;;
    *) die "Arquitetura não suportada: $arch" ;;
  esac

  local cpus ram_gb disk_gb
  cpus="$(nproc)"
  ram_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  disk_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"

  [[ "$cpus"    -ge "$MIN_CPUS"    ]] && ok "vCPU: $cpus"            || warn "vCPU: $cpus (recomendado: $MIN_CPUS+)"
  [[ "$ram_gb"  -ge "$MIN_RAM_GB"  ]] && ok "RAM: ${ram_gb} GB"      || warn "RAM: ${ram_gb} GB (recomendado: ${MIN_RAM_GB} GB+)"
  [[ "$disk_gb" -ge "$MIN_DISK_GB" ]] && ok "Disco livre: ${disk_gb} GB" || warn "Disco livre: ${disk_gb} GB (recomendado: ${MIN_DISK_GB} GB+)"

  curl -fsS --max-time 15 -o /dev/null https://get.k3s.io \
    || die "Sem acesso à internet. O script precisa baixar os instaladores e as imagens de container."
  ok "Acesso à internet"

  NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  [[ -n "${NODE_IP:-}" ]] || NODE_IP="$(hostname -I | awk '{print $1}')"
  [[ -n "${NODE_IP:-}" ]] || die "Não foi possível detectar o endereço IP da VM."
  ok "Endereço IP da VM: $NODE_IP"
}

# ------------------------------------------------------------------------------
#  2. Preparação do sistema operacional
# ------------------------------------------------------------------------------
prepare_os() {
  step "Preparando o sistema operacional"

  export DEBIAN_FRONTEND=noninteractive

  info "Atualizando a lista de pacotes..."
  apt-get update -qq
  if [[ "$APT_UPGRADE" == "true" ]]; then
    info "Atualizando os pacotes instalados (pode levar alguns minutos)..."
    apt-get upgrade -y -qq
  fi

  # open-iscsi é obrigatório para o Longhorn; nfs-common é exigido apenas por
  # volumes RWX, mas vem junto porque o preflight do Longhorn o verifica.
  info "Instalando dependências do Longhorn..."
  apt-get install -y -qq open-iscsi nfs-common util-linux curl
  systemctl enable --now iscsid >/dev/null 2>&1 || true
  systemctl is-active --quiet iscsid \
    && ok "iscsid ativo" \
    || die "O serviço iscsid não subiu. O Longhorn não funciona sem ele."

  if swapon --show | grep -q .; then
    info "Desativando o swap..."
    swapoff -a
    ok "Swap desativado"
  else
    ok "Swap já está desativado"
  fi
  # Comenta apenas as linhas de swap ainda ativas, para o script poder rodar de novo
  if grep -qE '^[^#]*[[:space:]]swap[[:space:]]' /etc/fstab; then
    sed -i -E '/^[[:space:]]*#/! s/^(.*[[:space:]]swap[[:space:]].*)$/#\1/' /etc/fstab
    ok "Entrada de swap comentada no /etc/fstab"
  fi

  # O multipathd captura os dispositivos do Longhorn e causa falhas de mount
  # difíceis de diagnosticar. Se estiver ativo, adiciona a exclusão.
  if systemctl is-active --quiet multipathd 2>/dev/null; then
    if [[ ! -f /etc/multipath/conf.d/99-longhorn.conf ]]; then
      mkdir -p /etc/multipath/conf.d
      cat > /etc/multipath/conf.d/99-longhorn.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
      systemctl restart multipathd
      ok "multipathd configurado para ignorar os dispositivos do Longhorn"
    fi
  fi
}

# ------------------------------------------------------------------------------
#  3. K3s
# ------------------------------------------------------------------------------
install_k3s() {
  step "Instalando o K3s ($K3S_VERSION)"

  if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
    ok "K3s já está instalado: $(k3s --version | head -1)"
  else
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh - >/dev/null
    ok "K3s instalado: $(k3s --version | head -1)"
  fi

  export KUBECONFIG="$KUBECONFIG_PATH"

  info "Aguardando o nó ficar pronto..."
  local i
  for i in $(seq 1 60); do
    if $KUBECTL get nodes 2>/dev/null | grep -q ' Ready '; then break; fi
    [[ $i -eq 60 ]] && die "O nó do cluster não ficou Ready em 5 minutos. Verifique: journalctl -u k3s -n 50"
    sleep 5
  done
  ok "Nó pronto: $($KUBECTL get nodes --no-headers | awk '{print $1" ("$5")"}')"

  if k3s check-config >/tmp/k3s-check-config.log 2>&1; then
    ok "k3s check-config: STATUS pass"
  else
    warn "k3s check-config reportou pendências. Detalhes em /tmp/k3s-check-config.log"
  fi

  # Deixa o kubectl utilizável pelo usuário que chamou o sudo
  local target_user target_home
  target_user="${SUDO_USER:-root}"
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  if [[ -n "$target_home" && -d "$target_home" ]]; then
    mkdir -p "$target_home/.kube"
    install -m 600 "$KUBECONFIG_PATH" "$target_home/.kube/config"
    chown -R "$target_user:$(id -gn "$target_user")" "$target_home/.kube"
    ok "kubeconfig disponível em $target_home/.kube/config"
  fi
}

# ------------------------------------------------------------------------------
#  4. Helm
# ------------------------------------------------------------------------------
install_helm() {
  step "Instalando o Helm"

  if command -v helm >/dev/null 2>&1; then
    ok "Helm já está instalado: $(helm version --short)"
  else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash >/dev/null 2>&1
    ok "Helm instalado: $(helm version --short)"
  fi
}

# ------------------------------------------------------------------------------
#  5. CRDs e controlador de snapshot
#     Vão ANTES do Longhorn: o sidecar csi-snapshotter do Longhorn entra em
#     CrashLoop se os CRDs de VolumeSnapshot ainda não existirem.
# ------------------------------------------------------------------------------
install_snapshot_support() {
  step "Instalando o suporte a snapshots CSI ($SNAPSHOTTER_VERSION)"

  local crd
  for crd in volumesnapshotclasses volumesnapshotcontents volumesnapshots; do
    $KUBECTL apply -f \
      "${SNAPSHOTTER_RAW}/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_${crd}.yaml" >/dev/null
    ok "CRD $crd"
  done

  $KUBECTL apply -f \
    "${SNAPSHOTTER_RAW}/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" >/dev/null
  $KUBECTL apply -f \
    "${SNAPSHOTTER_RAW}/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" >/dev/null

  # O manifesto padrão sobe 2 réplicas; em nó único uma é suficiente.
  $KUBECTL -n kube-system scale deployment/snapshot-controller --replicas=1 >/dev/null
  $KUBECTL -n kube-system rollout status deployment/snapshot-controller --timeout=300s >/dev/null \
    || die "O snapshot-controller não ficou pronto."
  ok "snapshot-controller em execução"
}

# ------------------------------------------------------------------------------
#  6. Longhorn
# ------------------------------------------------------------------------------
install_longhorn() {
  step "Instalando o Longhorn ($LONGHORN_VERSION)"

  helm repo add longhorn "$LONGHORN_REPO_URL" >/dev/null 2>&1 || true
  helm repo update >/dev/null

  info "Instalando o chart (pode levar de 5 a 10 minutos)..."
  helm upgrade --install "$LONGHORN_RELEASE" longhorn/longhorn \
    --namespace "$LONGHORN_NAMESPACE" \
    --create-namespace \
    --version "$LONGHORN_VERSION" \
    --set defaultSettings.defaultReplicaCount="$REPLICA_COUNT" \
    --set persistence.defaultClassReplicaCount="$REPLICA_COUNT" \
    --set csi.attacherReplicaCount=1 \
    --set csi.provisionerReplicaCount=1 \
    --set csi.resizerReplicaCount=1 \
    --set csi.snapshotterReplicaCount=1 \
    --set longhornUI.replicas=1 \
    --wait --timeout "$HELM_TIMEOUT" >/dev/null \
    || die "A instalação do Longhorn falhou. Verifique: kubectl get pods -n $LONGHORN_NAMESPACE"

  ok "Longhorn instalado"
  info "$($KUBECTL get pods -n "$LONGHORN_NAMESPACE" --no-headers | wc -l) pods em execução no namespace $LONGHORN_NAMESPACE"
}

# ------------------------------------------------------------------------------
#  7. StorageClass e VolumeSnapshotClass
# ------------------------------------------------------------------------------
configure_storage() {
  step "Configurando as classes de armazenamento"

  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "${REPLICA_COUNT}"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
  ok "StorageClass $STORAGE_CLASS criada e definida como padrão"

  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ${SNAPSHOT_CLASS}
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
EOF
  ok "VolumeSnapshotClass $SNAPSHOT_CLASS criada e marcada para o Kasten"

  # Garante que exista apenas uma StorageClass padrão
  local sc
  for sc in $($KUBECTL get storageclass -o jsonpath='{.items[*].metadata.name}'); do
    [[ "$sc" == "$STORAGE_CLASS" ]] && continue
    if [[ "$($KUBECTL get storageclass "$sc" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)" == "true" ]]; then
      $KUBECTL patch storageclass "$sc" \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
      ok "StorageClass $sc removida como padrão"
    fi
  done
}

# ------------------------------------------------------------------------------
#  8. Veeam Kasten
# ------------------------------------------------------------------------------
install_kasten() {
  step "Instalando o Veeam Kasten ($KASTEN_VERSION)"

  helm repo add kasten "$KASTEN_REPO_URL" >/dev/null 2>&1 || true
  helm repo update >/dev/null

  info "Executando o pre-flight (k10_primer)..."
  if curl -fsS "https://docs.kasten.io/downloads/${KASTEN_VERSION}/tools/k10_primer.sh" \
       | bash >/tmp/k10-primer.log 2>&1; then
    ok "Pre-flight concluído. Relatório em /tmp/k10-primer.log"
  else
    warn "O pre-flight reportou pendências. Relatório em /tmp/k10-primer.log"
  fi

  info "Instalando o chart (pode levar de 5 a 15 minutos)..."
  helm upgrade --install "$KASTEN_RELEASE" kasten/k10 \
    --namespace "$KASTEN_NAMESPACE" \
    --create-namespace \
    --version "$KASTEN_VERSION" \
    --set global.persistence.storageClass="$STORAGE_CLASS" \
    --set global.persistence.size="$KASTEN_PV_SIZE" \
    --set prometheus.server.persistentVolume.size="$KASTEN_PROMETHEUS_SIZE" \
    --set limiter.executorReplicas="$KASTEN_EXECUTOR_REPLICAS" \
    --wait --timeout "$HELM_TIMEOUT" >/dev/null \
    || die "A instalação do Kasten falhou. Verifique: kubectl get pods -n $KASTEN_NAMESPACE"

  ok "Veeam Kasten instalado"
  info "$($KUBECTL get pods -n "$KASTEN_NAMESPACE" --no-headers | wc -l) pods em execução no namespace $KASTEN_NAMESPACE"
}

# ------------------------------------------------------------------------------
#  9. Ingress das interfaces gráficas
# ------------------------------------------------------------------------------
configure_ingress() {
  step "Publicando as interfaces gráficas"

  # Com INGRESS_HOST vazio a regra não tem host e o Traefik atende em qualquer
  # nome ou IP — é o que dispensa configurar DNS ou /etc/hosts.
  local rule_head
  if [[ -n "$INGRESS_HOST" ]]; then
    rule_head="  - host: ${INGRESS_HOST}
    http:"
  else
    rule_head="  - http:"
  fi

  # Kasten em /k10 — precisa vir antes do Longhorn em /, pois o Traefik
  # prioriza o prefixo mais específico.
  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${KASTEN_INGRESS_NAME}
  namespace: ${KASTEN_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
${rule_head}
      paths:
      - path: /${KASTEN_URL_PATH}
        pathType: Prefix
        backend:
          service:
            name: gateway
            port:
              number: 80
EOF
  ok "Kasten publicado em /${KASTEN_URL_PATH}"

  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${LONGHORN_INGRESS_NAME}
  namespace: ${LONGHORN_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
${rule_head}
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
EOF
  ok "Longhorn publicado em /"

  # Confirma que o Traefik já está roteando, antes de dizer que está pronto
  local probe_host="${INGRESS_HOST:-$NODE_IP}" i code
  info "Verificando se as interfaces estão respondendo..."
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: ${probe_host}" "http://127.0.0.1/${KASTEN_URL_PATH}/" || true)"
    [[ "$code" =~ ^(200|301|302)$ ]] && break
    sleep 5
  done
  [[ "$code" =~ ^(200|301|302)$ ]] \
    && ok "Kasten respondendo (HTTP $code)" \
    || warn "Kasten ainda não respondeu (HTTP ${code:-sem resposta}). Aguarde e recarregue no navegador."

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
          -H "Host: ${probe_host}" "http://127.0.0.1/" || true)"
  [[ "$code" =~ ^(200|301|302)$ ]] \
    && ok "Longhorn respondendo (HTTP $code)" \
    || warn "Longhorn ainda não respondeu (HTTP ${code:-sem resposta})."
}

# ------------------------------------------------------------------------------
#  Resumo final
# ------------------------------------------------------------------------------
summary() {
  local base="http://${NODE_IP}"
  [[ -n "$INGRESS_HOST" ]] && base="http://${INGRESS_HOST}"

  printf '\n%s' "$C_GREEN$C_BOLD"
  printf '==============================================================================\n'
  printf '  Ambiente pronto\n'
  printf '==============================================================================%s\n' "$C_RESET"
  printf '\n'
  printf '  %sVeeam Kasten%s   %s/%s/#/\n' "$C_BOLD" "$C_RESET" "$base" "$KASTEN_URL_PATH"
  printf '  %sLonghorn%s       %s/\n' "$C_BOLD" "$C_RESET" "$base"
  printf '\n'
  printf '  %sVersões%s\n' "$C_BOLD" "$C_RESET"
  printf '    K3s %s · Longhorn %s · external-snapshotter %s · Kasten %s\n' \
    "$K3S_VERSION" "$LONGHORN_VERSION" "$SNAPSHOTTER_VERSION" "$KASTEN_VERSION"
  printf '\n'
  printf '  %sPrimeiros passos%s\n' "$C_BOLD" "$C_RESET"
  printf '    1. Abra a interface do Kasten pelo navegador da sua estação.\n'
  printf '    2. Informe e-mail e empresa e aceite os termos.\n'
  printf '    3. Em Settings > System Information, valide a StorageClass %s.\n' "$STORAGE_CLASS"
  printf '    4. Em Applications, crie uma política de snapshot para testar.\n'
  printf '\n'
  if [[ -n "$INGRESS_HOST" ]]; then
    printf '  %sDNS%s  adicione ao /etc/hosts da sua estação (não da VM):\n' "$C_BOLD" "$C_RESET"
    printf '    %s  %s\n\n' "$NODE_IP" "$INGRESS_HOST"
  fi
  printf '  %sObservações%s\n' "$C_BOLD" "$C_RESET"
  printf '    · As duas interfaces estão %ssem autenticação%s. Use apenas em rede local.\n' "$C_YELLOW" "$C_RESET"
  printf '    · Sem repositório externo, o Kasten faz %ssnapshots%s, que vivem junto do\n' "$C_YELLOW" "$C_RESET"
  printf '      volume. Para backup de verdade, adicione um Location Profile em\n'
  printf '      Profiles > Location (Veeam Data Cloud Vault, S3 ou Veeam Backup & Replication).\n'
  printf '    · O Kasten é gratuito para até 5 nós, com trial de 30 dias das funções avançadas.\n'
  printf '\n'
  printf '  %sComandos úteis%s\n' "$C_BOLD" "$C_RESET"
  printf '    kubectl get pods -A\n'
  printf '    kubectl get storageclass\n'
  printf '    kubectl get volumesnapshotclass\n'
  printf '\n'
}

# ------------------------------------------------------------------------------
main() {
  printf '%s' "$C_BOLD"
  printf '==============================================================================\n'
  printf '  Laboratório Veeam Kasten com K3s + Longhorn\n'
  printf '==============================================================================%s\n' "$C_RESET"
  printf '%s  K3s %s · Longhorn %s · Kasten %s%s\n' \
    "$C_DIM" "$K3S_VERSION" "$LONGHORN_VERSION" "$KASTEN_VERSION" "$C_RESET"

  local started; started=$(date +%s)

  precheck
  prepare_os
  install_k3s
  install_helm
  install_snapshot_support
  install_longhorn
  configure_storage
  install_kasten
  configure_ingress
  summary

  printf '%s  Concluído em %d minutos.%s\n\n' \
    "$C_DIM" "$(( ($(date +%s) - started) / 60 ))" "$C_RESET"
}

main "$@"
