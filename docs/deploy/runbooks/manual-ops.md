# Runbook — Operações manuais (ex-responsabilidades do zammad-init)

O serviço `zammad-init` não existe mais no Swarm; estes casos raros viram
operação manual no host (`prod-ndesk`).

## Primeiro install (banco vazio — só em desastre/ambiente novo)

```bash
docker run --rm --network ndesk-net \
  -e POSTGRESQL_HOST=zammad-postgresql -e POSTGRESQL_DB=zammad_production \
  -e POSTGRESQL_USER=<user> -e POSTGRESQL_PASS=<pass> -e POSTGRESQL_PORT=5432 \
  technewbyte/ndesk:<tag> \
  bash -c 'bundle exec rake db:create db:migrate db:seed'
```

## Reconfigurar Elasticsearch (es_url ficou persistido no banco; só se mudar o ES)

```bash
CID=$(docker ps -q --filter name=ndesk_zammad-railsserver | head -n1)
docker exec "$CID" bundle exec rails r \
  "Setting.set('es_url', 'http://zammad-elasticsearch:9200'); Setting.set('es_index', 'zammad')"
```

## Rebuild do índice de busca (índice sumiu/corrompeu ou ES novo)

```bash
CID=$(docker ps -q --filter name=ndesk_zammad-railsserver | head -n1)
docker exec "$CID" bundle exec rake zammad:searchindex:rebuild
```

## Restore de backup em produção (destrutivo — janela obrigatória)

1. Parar o app:

   ```bash
   docker service scale ndesk_zammad-railsserver=0 ndesk_zammad-nginx=0 \
     ndesk_zammad-websocket=0 ndesk_zammad-scheduler=0 ndesk_zammad-backup=0
   ```

2. Semear `restore/` no volume de backup (ver rehearsal.md §3).
3. `docker service scale ndesk_zammad-backup=1` → acompanhar logs até "Restore completed".
4. Redeployar a tag desejada: `bash /opt/ndesk/deploy/deploy.sh <tag> --skip-migrate`
