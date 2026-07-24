# Runbook — Cutover compose → Swarm (prod-ndesk)

Janela agendada e anunciada (~minutos). Executar num horário de baixo movimento.

Pré-requisitos:

- PR do deploy mergeado e `deploy/` presente em `/opt/ndesk/deploy`. Caminho principal é a cópia manual:
  `rsync -av deploy/ root@5.161.125.64:/opt/ndesk/deploy/`. Se preferir usar o workflow (dispatch) para entregar
  os arquivos antes do cutover, o run ficará VERMELHO no passo Deploy (o `ensure_network` falha sem Swarm) mas os
  arquivos já terão sido copiados — inofensivo.
- Backup do dia existente no volume `zammad_zammad-backup` (e no S3).
- Comparar os limites de memória dos containers atuais com o render do stack — divergência = ajustar o `.env`
  antes do cutover (o `deploy.sh` também falha no preflight se as variáveis de limite faltarem no `.env`):

  ```bash
  docker inspect --format '{{.Name}} {{.HostConfig.Memory}}' $(docker ps -q)
  RELEASE_TAG=<tag> bash -c 'set -a; source /opt/zammad/.env; set +a; docker stack config -c /opt/ndesk/deploy/stack.yml' | grep -A3 limits
  ```

- Hoje o compose já publica a 8080 em `0.0.0.0` (verificado em 2026-07-23); o ingress do Swarm mantém o mesmo
  comportamento — sem mudança de exposição. O acesso oficial continua sendo via Cloudflare Tunnel.
- Conferir que `/opt/zammad/.env` é seguro para `source` em bash (sem valores com espaços/`$`/backticks sem aspas)
  — o `deploy.sh` faz `source` nele, e o parser do compose é mais tolerante que o bash.

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
