# Deploy (Release & Operação)

Contexto do ciclo de release do NDesk em produção: como uma versão vira Release, como
chega ao ar sem derrubar o atendimento, e quando uma indisponibilidade é aceitável.
Glossário — sem detalhes de implementação.

## Linguagem

**Release**:
Uma versão específica do NDesk publicada sob uma tag `nb.*`. É a única coisa que pode
ir a produção, sempre referenciada pela tag exata — produção nunca aponta para `latest`.
_Evitar_: build, latest, "versão nova" sem tag

**Deploy quente**:
Troca da Release em produção durante o horário comercial, sem janela perceptível para
o atendente ou o cliente — no máximo um blip de segundos e reconexão automática. É o
caminho padrão de todo deploy.
_Evitar_: deploy com downtime "curto", restart

**Janela de manutenção**:
Deploy agendado e anunciado em que indisponibilidade é aceitável. Reservada para
mudanças incompatíveis com o Deploy quente — tipicamente lotes de migração pesados
vindos do upstream Zammad.
_Evitar_: downtime acidental (janela é sempre planejada)

**Cutover**:
A transição única, agendada, do modelo de deploy antigo para o novo. Acontece uma vez;
depois dela, todo deploy é quente ou por Janela de manutenção.
_Evitar_: migração (reservado para migração de banco)
