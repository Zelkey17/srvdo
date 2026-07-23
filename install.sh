#!/usr/bin/env bash
# Установщик srvdo.
#
#   curl -fsSL https://raw.githubusercontent.com/Zelkey17/srvdo/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Zelkey17/srvdo/main/install.sh | bash -s -- --uninstall
#   ./install.sh --help
#
set -eu

# ── что и откуда ──────────────────────────────────────────────────────────
REPO=${SRVDO_REPO:-Zelkey17/srvdo}          # репозиторий уже прописан
BRANCH=${SRVDO_BRANCH:-main}
PREFIX=${SRVDO_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/srvdo}
SHELLS=""                                # пусто → определить самим
ASSUME_YES=0
TOUCH_RC=1
ACTION=install

BEGIN_MARK='# >>> srvdo >>>'
END_MARK='# <<< srvdo <<<'

# ── оформление ────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && command -v tput >/dev/null 2>&1 \
   && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  B=$(tput bold); D=$(tput dim); R=$(tput sgr0)
  G=$(tput setaf 2); Y=$(tput setaf 3); E=$(tput setaf 1); C=$(tput setaf 6)
else B=; D=; R=; G=; Y=; E=; C=; fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$R" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$R" "$*" >&2; }
die()  { printf '%sсбой:%s %s\n' "$E" "$R" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
cmd()  { printf '  %s%s%s\n' "$C" "$*" "$R"; }

usage() {
  cat <<EOF
${B}srvdo — установка${R}

  ./install.sh [опции]

  --prefix=КАТАЛОГ     куда положить srvdo.sh (сейчас: $PREFIX)
  --shell=bash,zsh     в какие rc-файлы добавить строку (по умолчанию — во все найденные)
  --no-rc              не трогать ~/.bashrc и ~/.zshrc, только положить файл
  --branch=ВЕТКА       откуда качать при установке через curl (сейчас: $BRANCH)
  --uninstall          удалить srvdo
  -y, --yes            не задавать вопросов
  -h, --help           эта справка

Переменные окружения: SRVDO_REPO, SRVDO_BRANCH, SRVDO_PREFIX.
EOF
}

# ── разбор аргументов ─────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case $1 in
    --prefix=*) PREFIX=${1#*=} ;;
    --prefix)   PREFIX=${2:?--prefix без значения}; shift ;;
    --shell=*)  SHELLS=${1#*=} ;;
    --shell)    SHELLS=${2:?--shell без значения}; shift ;;
    --branch=*) BRANCH=${1#*=} ;;
    --no-rc)    TOUCH_RC=0 ;;
    --uninstall|--remove) ACTION=uninstall ;;
    -y|--yes)   ASSUME_YES=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "непонятная опция «$1». Справка: ./install.sh --help" ;;
  esac
  shift
done

# curl | bash — вопросы задавать некому
[ -t 0 ] || ASSUME_YES=1

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s (y/N): ' "$1"
  local a; IFS= read -r a || a=n
  case $a in [yYдД]*) return 0 ;; *) return 1 ;; esac
}

# ── какие rc-файлы правим ─────────────────────────────────────────────────
rc_files() {
  if [ -n "$SHELLS" ]; then
    local s
    printf '%s' "$SHELLS" | tr ',' '\n' | while IFS= read -r s; do
      case $s in
        bash) printf '%s\n' "$HOME/.bashrc" ;;
        zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
        *) warn "не знаю шелл «$s», пропускаю" ;;
      esac
    done
    return
  fi
  # по умолчанию — те, что уже есть, плюс rc текущего шелла
  [ -f "$HOME/.bashrc" ] && printf '%s\n' "$HOME/.bashrc"
  [ -f "${ZDOTDIR:-$HOME}/.zshrc" ] && printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
  case ${SHELL##*/} in
    bash) [ -f "$HOME/.bashrc" ] || printf '%s\n' "$HOME/.bashrc" ;;
    zsh)  [ -f "${ZDOTDIR:-$HOME}/.zshrc" ] || printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
  esac
}

rc_block_drop() {   # вырезать наш блок из файла
  local f=$1
  [ -f "$f" ] || return 0
  grep -qF "$BEGIN_MARK" "$f" || return 0
  cp "$f" "$f.srvdo-bak"
  sed -i "\|$BEGIN_MARK|,\|$END_MARK|d" "$f"
}

rc_block_add() {
  local f=$1
  mkdir -p "$(dirname "$f")"; touch "$f"
  rc_block_drop "$f"
  # убираем возможную пустую строку в конце, чтобы не плодить их
  printf '%s\n' "$BEGIN_MARK" >>"$f"
  printf '%s\n' "[ -f \"$PREFIX/srvdo.sh\" ] && . \"$PREFIX/srvdo.sh\"" >>"$f"
  printf '%s\n' "$END_MARK" >>"$f"
}

# ── удаление ──────────────────────────────────────────────────────────────
if [ "$ACTION" = uninstall ]; then
  step "Удаление srvdo"
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] && grep -qF "$BEGIN_MARK" "$f"; then
      rc_block_drop "$f"; ok "строка убрана из $f (копия: $f.srvdo-bak)"; n=$((n+1))
    fi
  done <<EOF
$(rc_files)
EOF
  [ "$n" = 0 ] && say "в rc-файлах ничего не нашлось"
  if [ -d "$PREFIX" ]; then rm -rf "$PREFIX"; ok "удалён $PREFIX"; fi
  CFG=${XDG_CONFIG_HOME:-$HOME/.config}/srvdo
  if [ -d "$CFG" ]; then
    if confirm "Удалить и настройки ($CFG)?"; then rm -rf "$CFG"; ok "настройки удалены"
    else say "настройки оставлены: $CFG"; fi
  fi
  say ""
  say "Записи Host в ~/.ssh/config и ключи не тронуты — их удаляйте вручную,"
  say "если они больше не нужны."
  exit 0
fi

# ── установка ─────────────────────────────────────────────────────────────
step "Установка srvdo"

# 1. проверка шелла
case ${BASH_VERSION:-} in
  '' ) : ;;
  [1-3].*|4.[0-2].*) warn "нужен bash 4.3+ или zsh; у вас bash ${BASH_VERSION}" ;;
esac

# 2. берём файл: из клона рядом, иначе качаем
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) 2>/dev/null || SELF_DIR=.
SRC=""
if [ -f "$SELF_DIR/srvdo.sh" ]; then
  SRC="$SELF_DIR/srvdo.sh"
  say "источник: локальный файл $SRC"
else
  URL="https://raw.githubusercontent.com/$REPO/$BRANCH/srvdo.sh"
  TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
  say "источник: $URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$TMP" || die "не удалось скачать (проверьте REPO, BRANCH и сеть)"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP" "$URL" || die "не удалось скачать (проверьте REPO, BRANCH и сеть)"
  else
    die "нужен curl или wget"
  fi
  SRC="$TMP"
fi

# 3. файл действительно наш и не битый
grep -q '^srvdo() {' "$SRC" || die "скачанный файл не похож на srvdo.sh"
if command -v bash >/dev/null 2>&1; then
  bash -n "$SRC" || die "в файле синтаксическая ошибка — установка отменена"
fi

# 4. кладём на место
mkdir -p "$PREFIX"
if [ -f "$PREFIX/srvdo.sh" ] && ! cmp -s "$SRC" "$PREFIX/srvdo.sh"; then
  cp "$PREFIX/srvdo.sh" "$PREFIX/srvdo.sh.bak"
  say "прежняя версия сохранена: $PREFIX/srvdo.sh.bak"
fi
cp "$SRC" "$PREFIX/srvdo.sh"
chmod 644 "$PREFIX/srvdo.sh"
ok "положено в $PREFIX/srvdo.sh"

# 5. строка в rc-файлы
if [ "$TOUCH_RC" = 1 ]; then
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rc_block_add "$f"; ok "строка добавлена в $f"; n=$((n+1))
  done <<EOF
$(rc_files)
EOF
  [ "$n" = 0 ] && warn "rc-файлов не нашлось — добавьте вручную: . $PREFIX/srvdo.sh"
else
  say "rc-файлы не тронуты (--no-rc). Добавьте сами:"
  cmd ". $PREFIX/srvdo.sh"
fi

# 6. зависимости
step "Зависимости"
miss=""
for c in ssh rsync; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"
  else printf '%s✗%s %s — обязателен\n' "$E" "$R" "$c"; miss="$miss $c"; fi
done
for c in tmux fzf inotifywait sshfs; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"
  else
    case $c in
      tmux)        printf '%s—%s tmux — нужен для сессий (ставится и на сервере)\n' "$Y" "$R" ;;
      fzf)         printf '%s—%s fzf — выбор сессий и портов по Tab\n' "$Y" "$R" ;;
      inotifywait) printf '%s—%s inotify-tools — нужен для srvdo watch\n' "$Y" "$R" ;;
      sshfs)       printf '%s—%s sshfs — нужен для srvdo mount\n' "$Y" "$R" ;;
    esac
    miss="$miss $c"
  fi
done
if [ -n "$miss" ]; then
  say ""
  if command -v apt-get >/dev/null 2>&1; then
    say "Поставить недостающее:"
    cmd "sudo apt install -y openssh-client rsync tmux fzf inotify-tools sshfs"
  elif command -v dnf >/dev/null 2>&1; then
    cmd "sudo dnf install -y openssh-clients rsync tmux fzf inotify-tools fuse-sshfs"
  elif command -v pacman >/dev/null 2>&1; then
    cmd "sudo pacman -S --needed openssh rsync tmux fzf inotify-tools sshfs"
  elif command -v brew >/dev/null 2>&1; then
    cmd "brew install rsync tmux fzf sshfs"
  fi
fi

# 7. что дальше
step "Готово"
case ${SHELL##*/} in
  zsh) cmd "source ${ZDOTDIR:-$HOME}/.zshrc" ;;
  *)   cmd "source $HOME/.bashrc" ;;
esac
cmd "srvdo init        # настроить сервер: адрес, юзер, ключ, алиас"
cmd "srvdo -h          # что умеет"
cmd "srvdo examples    # готовые сценарии"
say ""
say "${D}удалить: ./install.sh --uninstall${R}"
