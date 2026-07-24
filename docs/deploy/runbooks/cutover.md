# Runbook — Cutover compose → Swarm (prod-ndesk)

Janela agendada e anunciada (~minutos). Executar num horário de baixo movimento.
Pré-requisitos: PR do deploy mergeado; `deploy/` presente em `/opt/ndesk/deploy`
(rode o workflow uma vez com dispatch até o passo de scp, ou rsync manual:
`rsync -av deploy/ root@5.161.125.64:/opt/ndesk/deploy/`); backup do dia existente
no volume `zammad_zammad-backup` (e no S3).

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
   7946/tcp+udp, 4789/udp) estão bloqueadas:
   `sudo nmap -sT -sU -p T:2377,T:7946,U:7946,U:4789 5.161.125.64`
   → `closed|filtered` para todas as portas listadas (o scan UDP exige root).
   Se abertas, bloquear no firewall Hetzner/ufw ANTES de seguir.
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
