# Imark

Visualizador de Markdown nativo para macOS. Duplo clique num `.md` → abre
renderizado e recarrega sozinho quando guardas no editor.

Desenho e critérios de aceitação: [docs/DESIGN.md](docs/DESIGN.md).
Plano de implementação: [docs/PLAN.md](docs/PLAN.md).

## Compilar

Precisa de Xcode (Swift 6) e Node 20.

```bash
cd renderer && npm install && cd ..
./build.sh
```

Compila o bundle JS, compila o Swift, monta `Imark.app`, assina ad-hoc e
instala em `/Applications`.

| | |
|---|---|
| `./build.sh` | build + instalar |
| `./build.sh --debug` | compilação rápida, para iterar |
| `./build.sh --no-install` | fica só em `dist/Imark.app` |
| `IMARK_INSTALL_DIR=~/Applications ./build.sh` | instalar noutro sítio |

### Assinar com um Developer ID

Por omissão a build é assinada ad-hoc, o que chega para correr na máquina onde
foi compilada. Para uma build que corra noutro Mac sem o Gatekeeper reclamar,
passa a identidade:

```bash
IMARK_SIGN_IDENTITY="Developer ID Application: Nome (TEAMID)" ./build.sh
```

Com identidade, o script assina com `--options=runtime` e timestamp, que é o que
a notarização exige. Ver as identidades disponíveis: `security find-identity -v -p codesigning`.

Falta ainda notarizar antes de distribuir:

```bash
ditto -c -k --keepParent dist/Imark.app /tmp/Imark.zip
xcrun notarytool submit /tmp/Imark.zip --keychain-profile PERFIL --wait
xcrun stapler staple dist/Imark.app
```

## Usar

```bash
open -a Imark ficheiro.md
```

Para o pôr como app por omissão: Get Info num `.md` no Finder → *Open with* →
Imark → *Change All*.

## Estado

| Milestone | |
|---|---|
| M0 esqueleto, associação de ficheiros, spike de Quick Look | ✅ |
| M1 renderer | ✅ |
| M2 live reload | ✅ |
| M3 sidebar e índice | ✅ |
| M4 wiki-links e navegação | ✅ |
| M5 procura, tema, export, atalhos | ✅ |
| M6 Quick Look a sério | ✅ |
| M7 ícones e acabamentos | ✅ |

## Estrutura

```
Sources/Imark/           a app
Sources/ImarkQuickLook/  extensão de Quick Look
renderer/                fonte JS (markdown-it, highlight, mermaid, katex)
Resources/               gerado pelo build — não editar à mão
Support/                 Info.plist e entitlements
testdata/                ficheiros de teste
```

O ícone é desenhado por código a partir das regras em `docs/DESIGN.md`:

```bash
swift Support/make-icon.swift
```

## Ver o renderer sem abrir a app

`Support/shoot.swift` carrega uma página local num WebView fora do ecrã e grava
um PNG, para se poder iterar em CSS sem fotografar o ambiente de trabalho:

```bash
swift Support/shoot.swift file:///caminho/pagina.html saida.png "js opcional" "probe opcional" 420 1100
```

Os últimos dois argumentos recortam a fotografia. Ler o cabeçalho do ficheiro
antes de o usar — há duas armadilhas com o compositor.

Para as partes nativas, `Support/window-id.swift` dá o id de uma janela para se
fotografar só essa, em vez do ecrã todo:

```bash
screencapture -x -o -l"$(swift Support/window-id.swift Imark)" shot.png
```

O renderer é a única parte que sabe converter markdown. A app Swift trata de
janelas, ficheiros e navegação, e fala com ele por mensagens.
