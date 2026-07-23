---
status: accepted
---

# Deploy quente via Swarm single-node no próprio prod-ndesk

Para lançar Releases em horário comercial sem downtime perceptível, o host `prod-ndesk`
vira um Swarm de nó único e o stack passa a ser deployado com `docker stack deploy` em
rolling `start-first` gateado por healthcheck, com migração de banco rodando como job
one-shot **antes** da troca (stack antigo ainda servindo) e `failure_action: rollback`
como rede de segurança. Um nó só de Swarm parece uso atípico — o motivo é que o que se
quer do Swarm aqui não é clustering, e sim o **mecanismo de update**: roteamento apenas
para tasks healthy, `start-first` nativo e rollback automático, coisas que o docker
compose puro não oferece. Spec completa:
[2026-07-23-zero-downtime-deploy-design.md](../../superpowers/specs/2026-07-23-zero-downtime-deploy-design.md).

## Alternativas rejeitadas

- **Blue-green com compose puro + flip no proxy**: entrega o mesmo resultado, mas exige
  workflow com estado ("qual cor está ativa"), dobra de RAM em cada deploy e um script
  de orquestração próprio para manter — tudo que o Swarm dá pronto.
- **Só reordenar o fluxo atual** (migração antes do `up -d`): downtime cai de minutos
  para ~15–40s de boot do puma, mas continua havendo blip perceptível a cada deploy.
- **Mover o ndesk para o cluster Swarm da frota** (Traefik/Patroni): rolling idêntico
  de graça, porém acopla o helpdesk à frota e exige migração de dados e de ingress —
  esforço e risco desproporcionais ao objetivo desta rodada.

## Consequências

- O serviço `zammad-init` deixa de existir; migração e cache clear viram fases do
  pipeline. Primeiro-install/autowizard e rebuild de índice do ES viram runbook manual.
- Produção passa a referenciar a tag exata da Release (nunca `latest`) — pré-requisito
  para rollback por redeploy de tag.
- Migrações destrutivas/pesadas não podem ir pelo caminho quente (rodam contra o banco
  vivo com o código antigo servindo): usam Janela de manutenção, a critério de quem
  mergeia — sem enforcement mecânico, por decisão deliberada.
- Reverter depois = desfazer o cutover (voltar ao compose) e reescrever o workflow;
  os volumes permanecem intactos em qualquer direção.
