---
description: Open something in Imark for review and wait for the reviewer's notes
argument-hint: "[--diff | --staged | <ficheiro…>] [--no-wait]"
allowed-tools: Bash(node:*)
---

Abre um documento no Imark para o utilizador rever e espera pela decisão dele.

Corre isto, passando os argumentos tal como vieram:

```
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" review $ARGUMENTS
```

Sem argumentos, revê as alterações por commitar — o mesmo que `--diff`. Com
nomes de ficheiro, revê esses ficheiros.

O comando bloqueia até o utilizador comentar em **seguir** ou em **rever** dentro
da app. Isso é esperado e pode demorar: não o interrompas, não lhe ponhas
timeout, e não perguntes se já acabou.

Quando voltar:

- **SEGUIR** — está aprovado. Age sobre as notas que vierem (podem existir, e são
  correcções a fazer na mesma) e segue.
- **REVER** — não avances com o trabalho como estava. Trata cada nota como um
  pedido de alteração, diz o que vais mudar em resposta a cada uma, e volta a
  submeter.

Cita as notas pela citação a que se referem — “sobre X” — em vez de as numerar,
porque é assim que o utilizador as vê na app.

Se o comando disser que o Imark não está instalado, diz-lhe onde ficou o
documento e continua sem revisão.
