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

Quando voltar, o output traz a decisão e as notas, e no caso de recusa traz
também os passos a seguir. **Segue-os pela ordem em que vêm** — em particular,
responde ao utilizador antes de reescrever seja o que for, e pergunta em vez de
adivinhar quando uma nota for ambígua ou duas se contradisserem.

Cita as notas pela citação a que se referem — “sobre X” — em vez de as numerar,
porque é assim que o utilizador as vê na app.

Se o comando disser que o Imark não está instalado, diz-lhe onde ficou o
documento e continua sem revisão.
