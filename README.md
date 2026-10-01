# Laboratório Veeam Kasten com K3s e Longhorn

> Um script, uma VM Ubuntu 24.04, e você tem um Kubernetes com Longhorn e o Veeam Kasten pronto para uso.

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)
![K3s](https://img.shields.io/badge/K3s-v1.33.11%2Bk3s1-FFC61C?logo=k3s&logoColor=black)
![Longhorn](https://img.shields.io/badge/Longhorn-1.9.2-5F259F)
![Veeam Kasten](https://img.shields.io/badge/Veeam_Kasten-9.0.6-005F4B)

Este repositório automatiza a criação de um ambiente de laboratório para testar o **Veeam Kasten**, a solução de proteção de dados da Veeam para Kubernetes. Tudo roda em uma única máquina virtual, no seu próprio laptop.

> [!WARNING]
> **Ambiente de laboratório.** Nó único, uma réplica por volume e interfaces gráficas sem autenticação. As escolhas aqui existem para simplificar os testes e não devem ser reproduzidas em produção.

---

## Passo a passo detalhado

O tutorial completo de instalação e configuração do Kubernetes single-node com Longhorn e Veeam Kasten está no conzatech.com, em três partes:

1. [Instalação e configuração do K3s e Longhorn](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-1/)
2. [Instalação e configuração básica do Veeam Kasten](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-2/)
3. [Configuração de políticas de backup no Veeam Kasten](https://conzatech.com/testando-veeam-kasten-com-k3s-longhorn-parte-3/)

---

## Instalação automática

Se quiser simplesmente o ambiente pronto, execute o comando abaixo em uma VM Ubuntu Server 24.04 limpa com [endereço IP fixo](https://ubuntu.com/server/docs/explanation/networking/configuring-networks/) e no mínimo 2 vCPU, 6 GB memória RAM e 80 GB disco:

```bash
curl -fsSLO https://raw.githubusercontent.com/ricardoconzatti/veeam-partner-bootcamp-kasten/main/magic-kasten.sh
sudo bash magic-kasten.sh
```

O script leva menos de 15 minutos e ao final imprime os endereços de acesso do Veeam Kasten, do Longhorn e da aplicação de demonstração.
