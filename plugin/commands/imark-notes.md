---
description: Read the Imark comments out of a markdown file
argument-hint: "<ficheiro.md>"
allowed-tools: Bash(node:*)
---

Lê as notas que o utilizador deixou dentro de um ficheiro markdown com o Imark.

```
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" notes $ARGUMENTS
```

Não espera por nada e não abre a app — é para quando o utilizador já comentou e
diz "lê os meus comentários".

Cada nota traz a citação a que se refere, a secção onde caiu, e o bloco por
cima. Isso chega para saber sobre o que é sem abrir o ficheiro; abre-o na mesma
se precisares do contexto à volta.

Uma nota marcada como **órfã** perdeu a âncora: o texto citado já não existe no
documento. Vale como comentário, mas não presumas que a linha por cima é aquilo
a que se refere.

Trata cada nota como um pedido, responde a todas, e cita-as pela citação —
“sobre X” — que é como o utilizador as vê na app.
