# Telemetry-Driven Traffic Engineering — Project B

Implementação de um sistema de **In-Band Network Telemetry (INT)** com rerouting automático de tráfego, usando P4/bmv2, Mininet, um cNF dockerizado e um controlador SDN com P4Runtime.

## Visão Geral

```
Subnet 10.0.1.0/24          Subnet 10.0.2.0/24

h1 ─┐                               ┌─ h4
h2 ─┤── s1(L2) ── s2(L3) ────────── s4(L2) ─ h5
h3 ─┘         p4     p1 \   p3/               h6
                          \   /               │ p6
                     p2    \ /  p2           cNF (Docker)
                           s3(L3)

Short path : s1 → s2 → s4          (2 hops INT)
Long  path : s1 → s2 → s3 → s4    (3 hops INT)
```

O cNF analisa os cabeçalhos INT de pacotes clonados e reporta ao controlador via PacketIn. O plugin de Traffic Engineering deteta degradação de caminho e reconfigura as regras LPM em s2 automaticamente.

---

## Requisitos

- Python 3.10+
- Docker
- Mininet
- `simple_switch_grpc` (bmv2 com suporte P4Runtime)
- `p4c-bm2-ss` (compilador P4)
- `xterm`
- `netcat` (`nc`)

---

## Executar pela Primeira Vez

### 1. Instalar dependências Python do controlador

```bash
pip3 install grpcio grpcio-tools p4runtime scapy pyyaml
```

### 2. Compilar, construir o Docker e lançar tudo

```bash
sudo bash run_sim.sh
```

Este script faz automaticamente:
1. Compila os 4 programas P4 (`s1.p4` ... `s4.p4`) para `build/`
2. Constrói a imagem Docker do cNF (`int-cnf`)
3. Abre um terminal **Mininet** com a topologia completa
4. Cria o par veth (`veth-cnf0` / `veth-cnf1`) e liga `veth-cnf0` a s4 porta 6
5. Inicia o container **cNF** e move `veth-cnf1` para o seu namespace
6. Abre um terminal **Controlador** que instala todas as regras P4Runtime

### 3. Aguardar a inicialização

Nos terminais abertos, esperar pelas mensagens:
- **Controlador**: `all rules installed — network ready`
- **cNF**: `INT analyser listening on veth-cnf1`

### 4. Testar conectividade

No terminal Mininet:

```
mininet> h1 ping h4
mininet> h1 ping h5
```

### 5. Testar telemetria e Traffic Engineering

Gerar tráfego contínuo para ativar o INT:

```
mininet> h1 ping -f h4
```

Observar no terminal do **cNF** os registos INT por pacote e o baseline a ser estabelecido.

**Injetar degradação** (30ms de delay na ligação s1→s2):

```
mininet> s1 tc qdisc add dev s1-eth4 root netem delay 30ms
```

O cNF deteta a variação (>2% do baseline) e reporta `[DEGRADED]`. O controlador reconfigura s2 para usar o long path (s2→s3→s4) automaticamente.

**Remover o delay** para observar a recuperação:

```
mininet> s1 tc qdisc del dev s1-eth4 root
```

O sistema deteta a melhoria no long path e regressa ao short path.

---

## Estrutura do Projeto

```
lab_project/
+-- p4/
|   +-- headers.p4          # Tipos, constantes, INT headers, metadata
|   +-- s1.p4               # L2 switch + INT source (marking + insertion)
|   +-- s2.p4               # L3 router + INT transit
|   +-- s3.p4               # L3 router + INT transit (long path)
|   +-- s4.p4               # L2 switch + INT sink (clone + strip)
+-- controller/
|   +-- controller.py       # Motor de eventos + API P4Runtime
|   +-- plugin_base.py      # Interface base para plugins
|   +-- run_controller.py   # Ponto de entrada do controlador
|   +-- plugins/
|       +-- setup_plugin.py # Ligacao de switches, pipelines, regras base
|       +-- te_plugin.py    # Rececao de relatorios cNF e rerouting
+-- cNF/
|   +-- cnf.py              # Analyser INT: parsing, metricas, PathState
|   +-- cnf.yaml            # Configuracao de interface e enderecos
|   +-- Dockerfile.cnf      # Imagem Docker (python:3.11-slim + scapy)
+-- mininet/
|   +-- my_topo.py          # Topologia Mininet com 4 P4 switches e 6 hosts
+-- run_sim.sh              # Script unico: compila, constroi Docker, lanca tudo
```