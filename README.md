# Testando o Veeam Kasten com K3s e Longhorn

> Runbook consolidado de instalação e configuração de um cluster Kubernetes single-node para testes do Veeam Kasten.

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)
![K3s](https://img.shields.io/badge/K3s-v1.33.11%2Bk3s1-FFC61C?logo=k3s&logoColor=black)
![Longhorn](https://img.shields.io/badge/Longhorn-1.9.2-5F259F)
![Veeam Kasten](https://img.shields.io/badge/Veeam_Kasten-9.0.6-005F4B)

Este runbook consolida os comandos das três partes da série publicada em [conzatech.com](https://conzatech.com). O objetivo é mostrar, passo a passo, uma forma simplificada e rápida de fazer o deploy do K3s com Longhorn e usar o Veeam Kasten para proteger a carga de trabalho executada no Kubernetes.

O **K3s** é uma distribuição leve do Kubernetes, ideal para testes e ambientes com poucos recursos. O deploy padrão utiliza ao menos três nós, mas aqui será feito com apenas um. O **Longhorn** é a camada de armazenamento distribuído do Kubernetes e é o responsável por armazenar os volumes, réplicas e snapshots. Para armazenar os backups do Kasten, será utilizado um compartilhamento **NFS**.

> [!WARNING]
> Todas as escolhas de design e arquitetura deste documento foram feitas para ser o mais simples possível, com o objetivo de ter um ambiente funcional **para testes**. Há adaptações técnicas deliberadas — nó único, uma réplica, repositório NFS sem imutabilidade — que jamais devem ser reproduzidas em ambientes produtivos.

---

## Sumário

- [Como usar este documento](#como-usar-este-documento)
- [1. Requisitos](#1-requisitos)
  - [1.1 Máquina virtual](#11-máquina-virtual)
  - [1.2 Versões dos componentes](#12-versões-dos-componentes)
  - [1.3 Rede e resolução de nomes](#13-rede-e-resolução-de-nomes)
  - [1.4 Repositório de backup (NFS)](#14-repositório-de-backup-nfs)
- [2. Preparação do sistema operacional](#2-preparação-do-sistema-operacional)
- [3. Instalação dos componentes](#3-instalação-dos-componentes)
  - [3.1 K3s](#31-k3s)
  - [3.2 Helm](#32-helm)
  - [3.3 Longhorn](#33-longhorn)
  - [3.4 CRDs de snapshot](#34-crds-de-snapshot)
  - [3.5 Controladores de snapshot](#35-controladores-de-snapshot)
- [4. Configuração do K3s e Longhorn](#4-configuração-do-k3s-e-longhorn)
  - [4.1 StorageClass longhorn-single-replica](#41-storageclass-longhorn-single-replica)
  - [4.2 VolumeSnapshotClass longhorn-snapshot](#42-volumesnapshotclass-longhorn-snapshot)
  - [4.3 Remover a marcação de padrão das outras StorageClasses](#43-remover-a-marcação-de-padrão-das-outras-storageclasses)
  - [4.4 Validação](#44-validação)
  - [4.5 Ingress do Longhorn](#45-ingress-do-longhorn)
  - [4.6 Ajuste do espaço reservado no nó](#46-ajuste-do-espaço-reservado-no-nó)
- [5. Instalação e configuração do Veeam Kasten](#5-instalação-e-configuração-do-veeam-kasten)
  - [5.1 Repositório Helm](#51-repositório-helm)
  - [5.2 Pre-flight (k10_primer)](#52-pre-flight-k10_primer)
  - [5.3 Instalação do K10](#53-instalação-do-k10)
  - [5.4 Verificação dos pods](#54-verificação-dos-pods)
  - [5.5 Ingress do Kasten](#55-ingress-do-kasten)
  - [5.6 Primeiro acesso e validação da StorageClass](#56-primeiro-acesso-e-validação-da-storageclass)
  - [5.7 PersistentVolume e PersistentVolumeClaim para o NFS](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs)
  - [5.8 Validação do PV e do PVC](#58-validação-do-pv-e-do-pvc)
  - [5.9 Location Profile](#59-location-profile)
- [6. Validação: aplicação de teste, política e restore](#6-validação-aplicação-de-teste-política-e-restore)
  - [6.1 Deploy da aplicação Apache](#61-deploy-da-aplicação-apache)
  - [6.2 Personalizar a página inicial](#62-personalizar-a-página-inicial)
  - [6.3 Criar a política de backup](#63-criar-a-política-de-backup)
  - [6.4 Simular a perda total da aplicação](#64-simular-a-perda-total-da-aplicação)
  - [6.5 Restore](#65-restore)
- [Apêndice A. Comandos de verificação](#apêndice-a-comandos-de-verificação)
- [Apêndice B. Valores a ajustar no seu ambiente](#apêndice-b-valores-a-ajustar-no-seu-ambiente)
- [Referências](#referências)

---

## Como usar este documento

As seções 2 a 6 devem ser executadas **na ordem apresentada**. A sequência não é apenas didática: existem dependências reais entre as etapas.

- Os CRDs e os controladores de snapshot ([3.4](#34-crds-de-snapshot) e [3.5](#35-controladores-de-snapshot)) precisam existir **antes** de o Kasten ser instalado, porque o pre-flight valida as capacidades do driver CSI.
- A StorageClass `longhorn-single-replica` precisa estar criada e marcada como padrão ([4.1](#41-storageclass-longhorn-single-replica)) **antes** da instalação do Kasten, senão os volumes do próprio Kasten serão provisionados na StorageClass `local-path` do K3s.
- O PV e o PVC do NFS ([5.7](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs)) precisam estar em estado `Bound` **antes** de criar o Location Profile na interface do Kasten.

> [!NOTE]
> Valores como `longhorn.caverna.local`, `192.168.10.3` e `/mnt/Caverna_Pool_01/shares/lab-kubernetes` são específicos do ambiente original. O [Apêndice B](#apêndice-b-valores-a-ajustar-no-seu-ambiente) lista todos os valores que você precisa ajustar.

---

## 1. Requisitos

### 1.1 Máquina virtual

O ambiente consiste em uma única máquina virtual, que acumula as funções de control plane e worker node.

| Recurso | Especificação |
| --- | --- |
| Sistema operacional | Ubuntu Server 24.04 LTS |
| vCPU | 2 |
| Memória RAM | 6 GB |
| Disco | 80 GB |
| Acesso | Usuário com privilégios de root (`sudo`) |
| Internet | Necessária para download dos instaladores e das imagens de container |

### 1.2 Versões dos componentes

| Componente | Versão utilizada |
| --- | --- |
| K3s | `v1.33.11+k3s1` (Kubernetes 1.33) |
| Longhorn | 1.9.2 — o passo a passo foi testado nas versões 1.9.0 e 1.9.2 |
| Veeam Kasten (K10) | 9.0.6 |
| external-snapshotter (CRDs e controller) | v8.2.0 |
| Helm | 3 (script `get-helm-3`) |
| Ingress controller | Traefik, instalado por padrão junto com o K3s |

Todas as versões acima estão **fixadas nos comandos** deste runbook, para que o ambiente seja reproduzível. Se preferir sempre a última versão de cada componente, remova o `INSTALL_K3S_VERSION` da seção [3.1](#31-k3s) e os parâmetros `--version` das seções [3.3](#33-longhorn) e [5.3](#53-instalação-do-k10).

### 1.3 Rede e resolução de nomes

O acesso às interfaces gráficas é feito por Ingress, via nomes DNS. Os nomes precisam resolver para o endereço IP da máquina virtual — seja no seu servidor DNS, seja no arquivo `hosts` da estação de trabalho.

| Nome DNS | Destino |
| --- | --- |
| `longhorn.caverna.local` | Interface gráfica do Longhorn |
| `kasten.caverna.local` | Interface gráfica do Veeam Kasten (sufixo `/k10/#`) |
| `test1.caverna.local` | Aplicação Apache de teste |

### 1.4 Repositório de backup (NFS)

É necessário um compartilhamento NFS acessível pela máquina virtual, que será usado como repositório de backup do Kasten. No ambiente original foi utilizado um TrueNAS.

| Item | Valor de referência |
| --- | --- |
| Servidor NFS | `192.168.10.3` |
| Caminho exportado | `/mnt/Caverna_Pool_01/shares/lab-kubernetes` |
| Versão do NFS | 4.1 |
| Capacidade declarada | 100 GB |
| Modo de acesso | ReadWriteMany (RWX) |

> [!CAUTION]
> O repositório NFS **não oferece imutabilidade**, algo fundamental para a verdadeira proteção do ambiente. Serve para testes e laboratório, mas jamais para produção. Para produção, use o Veeam Data Cloud Vault ou aponte para os seus repositórios no Veeam Backup & Replication.

---

## 2. Preparação do sistema operacional

Antes de qualquer instalação, atualize o sistema operacional.

```bash
apt update && apt upgrade -y
```

Em seguida, desative o swap (requisito do Kubernetes), instale o cliente NFS e o `kubectl`.

```bash
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

apt install -y nfs-common

snap install kubectl --classic
```

A segunda linha comenta a entrada de swap no `/etc/fstab`, garantindo que ele não volte após um reboot. O pacote `nfs-common` é obrigatório para que o nó consiga montar o compartilhamento NFS que será usado como repositório de backup.

---

## 3. Instalação dos componentes

### 3.1 K3s

A instalação do K3s é feita por um único script. A variável `INSTALL_K3S_VERSION` fixa a versão — sem ela, o script instala a última release do canal estável. Depois da instalação, copie o kubeconfig para o diretório do usuário e ajuste as permissões, para poder usar o `kubectl` sem `sudo`.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.33.11+k3s1" sh -

k3s kubectl get nodes

cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chown $USER:$USER ~/.kube/config

k3s --version
k3s check-config
```

> [!IMPORTANT]
> É importante garantir o `STATUS: pass` no resultado do comando `k3s check-config`. Caso não passe, valide o que faltou e corrija antes de seguir.

> [!NOTE]
> Se o diretório `~/.kube` não existir, crie-o antes do `cp` com `mkdir -p ~/.kube`.

### 3.2 Helm

O Helm é o gerenciador de pacotes do Kubernetes e será usado para instalar o Longhorn e o Kasten. Uma única linha, sem configurações adicionais.

```bash
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
```

### 3.3 Longhorn

Adicione o repositório Helm do Longhorn e instale a versão 1.9.2 no namespace `longhorn-system`.

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version 1.9.2
kubectl get pods -n longhorn-system -w
```

Antes de seguir, garanta que não houve nenhum erro na instalação e que todos os pods do namespace `longhorn-system` estão sendo executados corretamente.

### 3.4 CRDs de snapshot

CRD é a sigla para *Custom Resource Definition* e é a forma que o Kubernetes oferece para você criar novos tipos de objetos. Neste caso, é preciso definir o que é um snapshot e como usá-lo — `VolumeSnapshot`, `VolumeSnapshotClass` e `VolumeSnapshotContent` são exemplos. Aplique os três CRDs do external-snapshotter.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml

kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml

kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
```

### 3.5 Controladores de snapshot

Os controladores são responsáveis por executar o snapshot de fato, ou seja, cuidam da criação, restauração e deleção dos snapshots usando o driver CSI. São dois manifestos: o RBAC e o controller em si.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml

kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

---

## 4. Configuração do K3s e Longhorn

### 4.1 StorageClass longhorn-single-replica

A StorageClass funciona como um menu de tipos de armazenamento: ela diz ao Kubernetes como e onde criar os volumes (PVCs). As opções de uma única réplica e `WaitForFirstConsumer` são pertinentes justamente por se tratar de um ambiente de nó único. Note a anotação que já define esta classe como padrão do cluster.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single-replica
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "1"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

> [!NOTE]
> Certas configurações feitas pelo console do Longhorn valem apenas para volumes criados pela própria GUI. É o caso do número de réplicas: o comando `kubectl patch -n longhorn-system setting default-replica-count --type=merge -p '{"value":"1"}'` não surtiria o efeito desejado, e por isso foi necessário criar uma nova StorageClass.

### 4.2 VolumeSnapshotClass longhorn-snapshot

O VolumeSnapshotClass é uma espécie de menu de tipos de snapshot: informa ao Kubernetes como criar e gerenciar os snapshots dos volumes. Sem esse recurso devidamente configurado, não seria possível fazer snapshots nem restaurar usando o Kasten. Observe a anotação `k10.kasten.io/is-snapshot-class`, que é justamente o que faz o Kasten reconhecer esta classe.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
EOF
```

### 4.3 Remover a marcação de padrão das outras StorageClasses

Como o `longhorn-single-replica` já foi definido como padrão do ambiente, é melhor ajustar as demais classes para garantir que não existam múltiplas opções marcadas como padrão. Remova a anotação da `local-path` (padrão do K3s) e da `longhorn` (criada pelo chart).

```bash
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

### 4.4 Validação

Verifique se o `longhorn-single-replica` aparece como `(default)`, com reclaim policy `Delete` e volume binding mode `WaitForFirstConsumer`. Faça também um double check se o `longhorn-snapshot` está apontando para o `driver.longhorn.io`.

```bash
kubectl get storageclass

kubectl get volumesnapshotclass
```

### 4.5 Ingress do Longhorn

Com o armazenamento configurado, publique a interface gráfica do Longhorn. O Traefik é a controladora de Ingress instalada por padrão junto com o K3s e é responsável por gerenciar endereços, domínios e certificados.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: longhorn.caverna.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
EOF
```

O acesso é feito pelo endereço definido em `host`, que neste exemplo ficou `http://longhorn.caverna.local`.

### 4.6 Ajuste do espaço reservado no nó

Vale entender como o Longhorn trata a utilização dos volumes. Se você criar um volume de 20 GB e ocupar apenas 200 MB, a coluna `allocated` vai exibir os 20 GB; com 2 réplicas, aparecerão 40 GB, e assim por diante. O Longhorn usa esse cálculo para reservar espaço para réplicas, snapshots e afins.

Se o total ultrapassar o limite do nó — no ambiente original, 52,81 GB — o status do nó muda para `unschedulable` e nada mais funciona. Para contornar isso em laboratório, acesse a interface do Longhorn, clique em **Edit node and disks** na coluna *Operation* e reduza o tamanho do armazenamento reservado.

> [!WARNING]
> Este é um ajuste de laboratório para operar com o mínimo de hardware possível. Em um ambiente produtivo, dimensionado corretamente, isso provavelmente não seria um problema — e a reserva de espaço não deveria ser reduzida.

---

## 5. Instalação e configuração do Veeam Kasten

### 5.1 Repositório Helm

```bash
helm repo add kasten https://charts.kasten.io/
helm repo update
```

### 5.2 Pre-flight (k10_primer)

Antes de instalar o Kasten, execute o pre-flight para validar se está tudo certo. O script realiza diversos testes para garantir que os pré-requisitos foram atendidos: validação das permissões, versão mínima do Kubernetes, capacidade do CSI, classes de storage e até o deploy de pods, para entender se existiria algum problema ao subir tudo. Ao concluir, tudo é desfeito e um relatório é exibido.

```bash
curl https://docs.kasten.io/downloads/9.0.6/tools/k10_primer.sh | bash
```

Além da versão mínima do Kubernetes e da capacidade computacional para subir os pods, o teste mais importante aqui é o das **capacidades do driver CSI**.

### 5.3 Instalação do K10

O deploy padrão poderia ser algo como `helm install k10 kasten/k10 --namespace=kasten-io`, mas aqui a versão do chart é fixada, o volume dos containers é reduzido, o namespace `kasten-io` é criado, o kubeconfig do K3s é informado explicitamente e o número de réplicas do executor é limitado a uma. A StorageClass definida como padrão já contempla a réplica única, mas a opção foi mantida para reforçar.

```bash
helm install k10 kasten/k10 \
  --namespace kasten-io \
  --create-namespace \
  --version 9.0.6 \
  --set prometheus.server.persistentVolume.size=4Gi \
  --set global.persistence.size=8Gi \
  --set limiter.executorReplicas=1 \
  --kubeconfig /etc/rancher/k3s/k3s.yaml
```

> [!TIP]
> O Veeam Kasten é gratuito para até 5 nós. De qualquer forma, há uma licença trial de 30 dias incluída, o que permite testar também todas as funcionalidades avançadas.

### 5.4 Verificação dos pods

```bash
kubectl get pods -n kasten-io
```

Prossiga somente quando todos os pods estiverem em execução.

### 5.5 Ingress do Kasten

Com os pods rodando, publique a interface gráfica. O backend é o service `gateway`, na porta 80.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kasten-traefik-ingress
  namespace: kasten-io
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: kasten.caverna.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gateway
            port:
              number: 80
EOF
```

### 5.6 Primeiro acesso e validação da StorageClass

A URL de acesso é o hostname definido no YAML acrescido de `/k10/#`. No exemplo, ficou `http://kasten.caverna.local/k10/#`. No primeiro acesso será necessário informar o e-mail, o nome da empresa e aceitar os termos.

A primeira configuração recomendada é navegar até **Settings > System Information** e, na seção *Storage Classes*, selecionar `longhorn-single-replica` e validar pelo botão no canto superior direito. É esperado que, após alguns segundos, o status fique como `Valid`.

### 5.7 PersistentVolume e PersistentVolumeClaim para o NFS

Sem nenhuma configuração adicional já seria possível navegar até *Applications* e começar a fazer snapshots das aplicações — mas **snapshot não é backup**. Na prática, o snapshot fica junto com o volume e, no momento em que o volume é removido, o snapshot é removido também.

Para estar realmente protegido, é necessário fornecer um local externo para o Kasten armazenar esses dados. Neste laboratório, o destino é um servidor de arquivos NFS. O Kubernetes não entende o compartilhamento NFS diretamente: ele só o compreende por meio de recursos, e é exatamente aí que entram o PersistentVolume (PV) e o PersistentVolumeClaim (PVC). O PV faz um mapa fixo dizendo "isso aqui é um pedaço de NFS que você pode usar", e o Kasten se beneficia do PVC para de fato usar aquele pedaço. São as peças fundamentais para que o Kasten consiga ler e gravar os dados no NFS.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: truenas-nfs
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - hard
    - nfsvers=4.1
  nfs:
    server: 192.168.10.3
    path: /mnt/Caverna_Pool_01/shares/lab-kubernetes
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: truenas-nfs
  namespace: kasten-io
spec:
  volumeName: truenas-nfs
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ""
EOF
```

> [!IMPORTANT]
> Ajuste o YAML com os detalhes do seu ambiente: o endereço do servidor NFS, o caminho exportado e a capacidade.

### 5.8 Validação do PV e do PVC

Valide se o PV e o PVC foram criados corretamente. É esperado que o status seja `Bound` e o access mode seja `RWX`.

```bash
kubectl get pvc -n kasten-io
kubectl get pv truenas-nfs
```

### 5.9 Location Profile

Com os recursos criados, crie o Location Profile na interface do Kasten, em **Profiles > Location > Create New Profile**. Existem muitas opções de destino; seguindo o padrão de escolhas simplificadas deste laboratório, selecione **NFS/SMB** e informe o nome do recurso e o caminho exatamente como foram criados no PV e no PVC. Se estiver tudo correto, clique em **Submit**.

Ao final, confirme que o perfil foi criado com sucesso. Observe que a coluna de imutabilidade deixa explícito que não existe imutabilidade neste repositório — ou seja, pode ser usado para testes e laboratório, mas jamais em ambientes produtivos.

---

## 6. Validação: aplicação de teste, política e restore

### 6.1 Deploy da aplicação Apache

Para validar o ambiente, crie uma aplicação de teste. A ideia é manter o mesmo padrão de simplicidade e fazer o deploy de um Apache bem simples, mas protegendo o artefato de forma completa: deployment, service, volume persistente, ingress e namespace. Observe que o PVC usa a StorageClass `longhorn-single-replica`.

```bash
kubectl create namespace apache-test

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: apache-html-pvc
  namespace: apache-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Mi
  storageClassName: longhorn-single-replica
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apache-test
  namespace: apache-test
spec:
  selector:
    matchLabels:
      app: apache-test
  template:
    metadata:
      labels:
        app: apache-test
    spec:
      containers:
      - name: apache
        image: httpd:2.4
        ports:
        - containerPort: 80
        volumeMounts:
        - name: apache-html
          mountPath: /usr/local/apache2/htdocs
      volumes:
      - name: apache-html
        persistentVolumeClaim:
          claimName: apache-html-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: apache-test
  namespace: apache-test
spec:
  selector:
    app: apache-test
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apache-test-ingress
  namespace: apache-test
spec:
  ingressClassName: traefik
  rules:
  - host: test1.caverna.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: apache-test
            port:
              number: 80
EOF
```

### 6.2 Personalizar a página inicial

Só para enfeitar um pouco e ter um conteúdo identificável no volume persistente:

```bash
kubectl exec -n apache-test -it deploy/apache-test -- bash -c 'echo "<h1>Veeam Kasten</h1>" > /usr/local/apache2/htdocs/index.html'
```

Se tudo foi criado corretamente, basta abrir `http://test1.caverna.local` no navegador.

### 6.3 Criar a política de backup

No menu **Applications** do Veeam Kasten você provavelmente verá `apache-test`, `default` e `longhorn-system`, todos com a coluna *Compliance* em `Unmanaged` — ou seja, não estão sendo protegidos. Em `apache-test`, clique nos três pontos e em **Create a Policy**.

Para o teste, mantenha quase tudo no padrão e altere apenas a opção **Enable Backups via Snapshot Exports**, para que todos os snapshots sejam enviados ao repositório NFS usando a mesma retenção aplicada ao snapshot.

> [!IMPORTANT]
> Este é um ponto importante: existem configurações de retenção **separadas** para o snapshot e para os backups que vão ao repositório. Sem marcar essa opção e selecionar o repositório, o resultado seria apenas snapshots — e não backups.

Após criar a política, ela fica disponível no menu **Policies**. É esperado ver `Valid` no campo *Validation*, o recurso protegido correto e a ação como `Snapshot + Export`. Voltando ao menu **Applications**, o `apache-test` deve aparecer como `Compliant`.

### 6.4 Simular a perda total da aplicação

Com o primeiro backup concluído, o próximo passo é validar se é possível restaurar tudo no caso de perder a aplicação inteira. Para isso, destrua o `apache-test` por completo: deployment, services, ingress, PVC e namespace.

```bash
kubectl delete all --all -n apache-test
kubectl delete ingress apache-test-ingress -n apache-test
kubectl delete pvc apache-html-pvc -n apache-test
kubectl delete namespace apache-test
```

> [!CAUTION]
> Estes comandos destroem todos os recursos do namespace `apache-test` de forma irreversível. Execute apenas no ambiente de laboratório e confirme o namespace antes de rodar.

### 6.5 Restore

Ao navegar até **Applications**, o `apache-test` não aparece mais. Já em **Restore Points** é possível ver dois tipos de ponto de restauração: `Exported` e `Snapshot`.

O que salva neste cenário é o **Exported**: é o ponto de restauração armazenado no NFS, que não foi removido junto com a aplicação. O snapshot vivia junto do volume e desapareceu com ele. Note também o cadeado aberto ao lado do nome do repositório, que serve como lembrete de que ele não é imutável.

Ao iniciar o restore, o Kasten exibe um aviso informando que o restore point está fora do cluster e que a restauração pode precisar de mais tempo para trazer os dados, importar e fazer a restauração em si. Na sequência é possível escolher exatamente o que restaurar: neste caso, como tudo foi removido, selecione todos os itens. Em outra situação, seria possível selecionar granularmente apenas um volume, service, ingress e assim por diante.

Concluído o restore, a aplicação volta exatamente como estava. Com isso, o ambiente está completamente funcional para testar o Veeam Kasten, fazer backups e restaurações.

---

## Apêndice A. Comandos de verificação

Resumo dos comandos usados ao longo do documento para validar cada etapa.

| Comando | O que valida |
| --- | --- |
| `k3s check-config` | Pré-requisitos do K3s no sistema operacional. Deve retornar `STATUS: pass` |
| `k3s kubectl get nodes` | Nó do cluster em estado `Ready` |
| `kubectl get pods -n longhorn-system -w` | Todos os pods do Longhorn em execução |
| `kubectl get storageclass` | `longhorn-single-replica` marcada como `(default)`, reclaim policy `Delete` e binding mode `WaitForFirstConsumer` |
| `kubectl get volumesnapshotclass` | `longhorn-snapshot` apontando para `driver.longhorn.io` |
| `curl .../k10_primer.sh \| bash` | Pré-requisitos do Kasten, com destaque para as capacidades do driver CSI |
| `kubectl get pods -n kasten-io` | Todos os pods do Kasten em execução |
| `kubectl get pvc -n kasten-io` | PVC `truenas-nfs` em estado `Bound`, modo `RWX` |
| `kubectl get pv truenas-nfs` | PV `truenas-nfs` em estado `Bound` |

---

## Apêndice B. Valores a ajustar no seu ambiente

Todos os valores abaixo são específicos do ambiente original e precisam ser revisados antes da execução.

| Valor no documento | Onde aparece e o que é |
| --- | --- |
| `longhorn.caverna.local` | [4.5](#45-ingress-do-longhorn) — hostname do Ingress da GUI do Longhorn |
| `kasten.caverna.local` | [5.5](#55-ingress-do-kasten) — hostname do Ingress da GUI do Kasten |
| `test1.caverna.local` | [6.1](#61-deploy-da-aplicação-apache) — hostname do Ingress da aplicação de teste |
| `192.168.10.3` | [5.7](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs) — endereço IP do servidor NFS |
| `/mnt/Caverna_Pool_01/shares/lab-kubernetes` | [5.7](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs) — caminho exportado no servidor NFS |
| `100Gi` | [5.7](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs) — capacidade declarada do PV e requisitada pelo PVC |
| `truenas-nfs` | [5.7](#57-persistentvolume-e-persistentvolumeclaim-para-o-nfs) — nome do PV e do PVC; precisa ser informado igual no Location Profile |
| `v1.33.11+k3s1` | [3.1](#31-k3s) — versão do K3s fixada em `INSTALL_K3S_VERSION` |
| `1.9.2` | [3.3](#33-longhorn) — versão do chart do Longhorn (testado em 1.9.0 e 1.9.2) |
| `v8.2.0` | [3.4](#34-crds-de-snapshot) e [3.5](#35-controladores-de-snapshot) — versão do external-snapshotter |
| `9.0.6` | [5.2](#52-pre-flight-k10_primer) e [5.3](#53-instalação-do-k10) — versão do Kasten, no script de pre-flight e no `--version` do chart; as duas devem ser iguais |

---

## Referências

Série original de três artigos, publicada em conzatech.com:

1. [Parte 1 — Instalação e configuração do K3s e Longhorn](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-1/)
2. [Parte 2 — Instalação e configuração básica do Veeam Kasten](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-2/)
3. [Parte 3 — Configuração de políticas de backup no Veeam Kasten](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-3/)

Documentação oficial:

- [Veeam Kasten Documentation](https://docs.kasten.io/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [K3s Documentation](https://docs.k3s.io/)

---

<sub>Autor: Ricardo Conzatti · Compilado em 29 de setembro de 2026 · Ambiente de laboratório, não use em produção.</sub>
