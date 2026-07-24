# Runbook — Operações manuais (ex-responsabilidades do zammad-init)

O serviço `zammad-init` não existe mais no Swarm; estes casos raros viram
operação manual no host (`prod-ndesk`).

## Primeiro install (banco vazio — só em desastre/ambiente novo)

```bash
docker run --rm --network ndesk-net \
  -e POSTGRESQL_HOST=zammad-postgresql -e POSTGRESQL_DB=zammad_production \
  -e POSTGRESQL_USER=<user> -e POSTGRESQL_PASS=<pass> -e POSTGRESQL_PORT=5432 \
  -e REDIS_URL=redis://zammad-redis:6379 \
  -e MEMCACHE_SERVERS=zammad-memcached:11211 \
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
   Em seguida, limpar o resíduo do restore (senão, em imagens anteriores ao fix do
   `backup.sh`, o serviço de backup crash-loopa no próximo start — achado do ensaio):
   `docker run --rm -v zammad_zammad-backup:/b alpine sh -c 'rm -rf /b/restore_completed_*'`
4. Redeployar a tag desejada: `bash /opt/ndesk/deploy/deploy.sh <tag> --skip-migrate`
5. Rodar o **Rebuild do índice de busca** (seção acima) — o restore rebobina DB+storage
   mas NÃO o volume do Elasticsearch; sem reindex a busca fica dessincronizada.

## Migração falhou durante Janela de manutenção

O app está deliberadamente a 0 réplicas quando a migração roda; se ela falha, o
script morre e o app CONTINUA parado (a janela segue aberta). Opções:

1. Corrigir a causa e re-disparar o mesmo workflow dispatch — todas as fases são
   idempotentes.
2. Reabrir já na versão anterior: `bash /opt/ndesk/deploy/deploy.sh <tag-anterior> --skip-migrate`.

Atenção: cada migração Rails commita individualmente — um lote pode ter ficado
parcialmente aplicado. Migrações aditivas convivem com o código antigo, mas se a
migração que falhou era destrutiva, avaliar o Restore (seção anterior) antes de
reabrir.
