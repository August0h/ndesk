# Runbook — Cutover compose → Swarm (prod-ndesk)

Janela agendada e anunciada (~minutos). Executar num horário de baixo movimento.

Pré-requisitos:

- PR do deploy mergeado e `deploy/` presente em `/opt/ndesk/deploy`. Caminho principal é a cópia manual:
  `rsync -av deploy/ root@5.161.125.64:/opt/ndesk/deploy/`. Se preferir usar o workflow (dispatch) para entregar
  os arquivos antes do cutover, o run ficará VERMELHO no passo Deploy (o `ensure_network` falha sem Swarm) mas os
  arquivos já terão sido copiados — inofensivo.
- Backup do dia existente no volume `zammad_zammad-backup` (e no S3).
- Comparar os limites de memória e CPU dos containers atuais com o render do stack — divergência = ajustar o `.env`
  antes do cutover (o `deploy.sh` também falha no preflight se as variáveis de limite de memória faltarem no `.env`):

  ```bash
  docker inspect --format '{{.Name}} cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}}' $(docker ps -q)
  RELEASE_TAG=<tag> bash -c 'set -a; source /opt/zammad/.env; set +a; docker stack config -c /opt/ndesk/deploy/stack.yml' | grep -A3 limits
  ```

  Verificado em 2026-07-24 que prod já roda `cpus=1.0` (NanoCpus 1000000000) em todos os serviços via scenario de
  limits e não há vars `_CPUS` no `.env` — os defaults do stack.yml são paridade exata; a comparação existe para
  detectar drift até o dia do cutover.

- Hoje o compose já publica a 8080 em `0.0.0.0` (verificado em 2026-07-23); o ingress do Swarm mantém o mesmo
  comportamento — sem mudança de exposição. O acesso oficial continua sendo via Cloudflare Tunnel.
- Conferir que `/opt/zammad/.env` é seguro para `source` em bash (sem valores com espaços/`$`/backticks sem aspas)
  — o `deploy.sh` faz `source` nele, e o parser do compose é mais tolerante que o bash. O próprio
  `deploy.sh` detecta e falha listando as linhas inseguras, mas conserte ANTES do cutover para não
  gastar janela: hoje a linha `ELASTICSEARCH_JAVA_OPTS=-Xms6g -Xmx6g` de prod precisa ganhar aspas
  duplas no valor (achado do ensaio de 2026-07-24; aspas são compatíveis com o compose).
- Conferir que a versão do cloudflared rodando hoje (`docker exec zammad-cloudflare-tunnel-1 cloudflared --version`)
  bate com o pin do `stack.yml` (`cloudflare/cloudflared:2026.7.2`, conferido em 2026-07-24) — o tunnel é o único
  componente que o ensaio não exercitou (rodou com replicas=0 para proteger o tráfego real); divergência =
  atualizar o pin antes da janela.
- `docker pull technewbyte/ndesk:<TAG>` antes da janela (aquece o cache de imagem; a projeção de ~5 min de janela
  assume pull quente).

## Passos

1. **Identificar a tag em produção** (o cutover NÃO muda a versão do app):
   `docker exec zammad-zammad-railsserver-1 cat VERSION`
   O sufixo é a tag (ex.: `7.0.0-nb.14` → `TAG=nb.14`). Se o sufixo for `sha-*`,
   crie antes uma tag `nb.*` desse commit e espere o build publicar.
2. **Derrubar o stack compose** (a janela começa aqui; volumes ficam intactos):

   ```bash
   cd /opt/zammad && docker compose -f docker-compose.yml \
     -f scenarios/add-cloudflare-tunnel.yml -f scenarios/apply-resource-limits.yml down
   ```

3. **Ativar o Swarm:** `docker swarm init --advertise-addr 5.161.125.64`
4. **Firewall:** confirmar de FORA do host que as portas de Swarm (2377/tcp,
   7946/tcp+udp, 4789/udp) estão bloqueadas e que a 8080 continua como hoje:
   `sudo nmap -sT -sU -p T:2377,T:7946,T:8080,U:7946,U:4789 5.161.125.64`
   → `closed|filtered` para TODAS as portas listadas — inclusive a 8080, pois neste
   momento o compose já caiu e nada escuta nela (o scan UDP exige root). Se alguma
   porta de Swarm estiver aberta, bloquear no firewall Hetzner/ufw ANTES de seguir.
   Após o passo 6, repetir só a 8080 (`nmap -sT -p 8080 5.161.125.64`) → `open`,
   igual a hoje (paridade de exposição, ver pré-requisitos).
5. **Subir o stack** (mesma tag, sem migração — a janela acaba quando convergir):
   `bash /opt/ndesk/deploy/deploy.sh "$TAG" --skip-migrate`
6. **Verificar:**
   - `docker service ls` → todos `1/1`, imagem `technewbyte/ndesk:$TAG`
   - `curl -sf -o /dev/null -w '%{http_code}\n' https://<ZAMMAD_FQDN>/` → `200`
   - Login no app, abrir um ticket, confirmar indicador de websocket/presença
   - `docker service logs --since 5m ndesk_zammad-scheduler` → background rodando
7. **Evidência:** salvar `docker service ls` + smoke em `docs/deploy/evidence/`.

## Rollback do cutover

```bash
docker stack rm ndesk
until docker network rm ndesk-net; do sleep 2; done
docker swarm leave --force
cd /opt/zammad && docker compose -f docker-compose.yml \
  -f scenarios/add-cloudflare-tunnel.yml -f scenarios/apply-resource-limits.yml up -d
```

(Volumes intactos; o app volta ao estado pré-cutover em ~1 restart clássico.)

## Pós-cutover

- O cron `s3-backup.sh` continua válido (o volume `zammad_zammad-backup` não mudou).
- Os arquivos compose de `/opt/zammad` ficam no lugar como rota de fuga. NÃO apagar.
- A partir daqui, todo deploy é pelo workflow (tag `nb.*` ou dispatch).
- Evitar deploys entre 06:00–07:00 UTC (backup interno às 06:00, upload S3 às 07:00 — um deploy recria o serviço
  de backup stop-first e pode truncar o dump); se inevitável, conferir o backup do dia no S3 depois.
