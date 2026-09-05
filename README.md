# 🎐 Soprano

Controle das ventoinhas do Mac direto na barra de menu — estilo "barra de volume".
Um slider pra subir/descer a rotação, uma curva automática por temperatura e leitura
ao vivo de rotação e temperatura do CPU.

Feito e testado em **MacBook Pro M4 (Apple Silicon), macOS 26**.

<p align="center">
  <img src="docs/screenshot.png" alt="Soprano na barra de menu" width="360">
</p>

---

## Requisitos

- Mac com **Apple Silicon** (M1/M2/M3/M4).
- **Xcode Command Line Tools** (fornece o `swiftc`). Se não tiver:
  ```bash
  xcode-select --install
  ```
- Permissão de administrador (o controle do fan exige root — veja abaixo).

---

## Instalar

Clone o repositório e rode:

```bash
git clone https://github.com/bellinivitor/Soprano.git
cd Soprano
./build.sh && ./install.sh
```

- `build.sh` — compila o CLI `smcfan` e monta o `Soprano.app` (não precisa de senha).
- `install.sh` — copia o `smcfan` para `/usr/local/bin` e cria uma regra `sudoers`
  que permite ao app acionar **apenas** esse binário sem pedir senha a cada ajuste.
  **Pede sua senha uma única vez.**

> Por que root? Ajustar a rotação significa escrever nas chaves do SMC
> (System Management Controller), o que exige privilégio de administrador.
> A leitura (rotação/temperatura) não precisa.

---

## Abrir

```bash
open build/Soprano.app
```

O ícone 🌀 aparece na **barra de menu** (canto superior direito), com a rotação e a
temperatura ao lado. Clique nele para abrir o painel. Se quiser que ele abra sozinho,
adicione o `Soprano.app` aos **Itens de Início de Sessão** (Ajustes do Sistema → Geral).

---

## Usar

- **Slider** (🐢 ↔ 🐇): arraste para definir a rotação. Ao arrastar, o app assume o
  controle manual na hora.
- **Modo** (segmented):
  - **Automático** — devolve o fan ao controle térmico do macOS.
  - **Manual** — mantém a rotação do slider.
  - **Curva** — ajusta a rotação automaticamente conforme a temperatura do CPU.
- **Temperatura**: média dos sensores de die do CPU, com cor (verde/laranja/vermelho).
- **Configurações** (ícone 🎚️, ao lado do "Sair") — abre uma janela com abas:
  - **Curva** — edita os pontos temperatura → rotação, adiciona/remove pontos e
    **reseta para o padrão**.
  - **Aplicativos** — regras **por app**: quando o app abrir (ex.: um jogo), o fan vai
    pro **%** definido; ao fechar, volta pro modo anterior. Se vários estiverem abertos,
    vale o maior %. Dá pra escolher entre os apps abertos ou procurar no `/Applications`.
  - **Barra de menu** — liga/desliga o que aparece ao lado do ícone (**rotação** e/ou
    **temperatura**).

---

## ⚠️ Importante

- **Não rode junto com o Macs Fan Control** (ou outro controlador de fan). Dois
  controladores brigando pelo SMC travam a firmware do fan. O app avisa em laranja se
  detectar o Macs Fan Control aberto. Se o daemon dele estiver ativo em background,
  desinstale-o.
- **Segurança térmica**: forçar rotação baixa sob carga pesada pode superaquecer, já
  que você tira o gerenciamento do macOS. Na dúvida, use **Automático**.

---

## Atualizar

Novas versões saem aqui no GitHub — acompanhe o repositório. Para atualizar:

```bash
cd Soprano && git pull && ./build.sh
```

(O link e essa instrução também estão dentro do app, na aba **Sobre**.)

---

## Desinstalar

```bash
./uninstall.sh
```

Fecha o app, devolve o fan ao automático e remove o binário `smcfan`, a regra de
sudo, o `Soprano.app` e as preferências salvas.

---

## Como funciona

- `smcfan/` — CLI mínimo em Swift que fala com o **AppleSMC** via IOKit
  (`read`, `temp`, `set <i> <rpm>`, `auto [<i>]`).
- `app/App.swift` — app SwiftUI de barra de menu. Lê o SMC direto (sem root) e, para
  escrever, chama `/usr/local/bin/smcfan` via `sudo -n` (regra instalada pelo
  `install.sh`). Enquanto controla, reafirma o alvo periodicamente ("keep-alive")
  para manter o modo forçado estável.

---

## Licença

MIT — veja [LICENSE](LICENSE).
