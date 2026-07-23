#!/usr/bin/env bash
# srvdo — единая обёртка над ssh/tmux/rsync.
#   установка:  source ~/srvdo.sh   (в ~/.bashrc)
#   начало:     srvdo init
#   справка:    srvdo -h  ·  srvdo КОМАНДА ?  ·  srvdo examples

# ── настройки ─────────────────────────────────────────────────────────────
: "${SRVDO_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/srvdo/config}"
[ -f "$SRVDO_CONFIG" ] && . "$SRVDO_CONFIG"

: "${SRVDO_HOST:=srv}"
: "${SRVDO_DIR:=/root}"
: "${SRVDO_EDITOR:=}"                     # пусто → $VISUAL/$EDITOR → выбор из установленных
: "${SRVDO_PEEK:=60}"
: "${SRVDO_MOUNT_BASE:=$HOME/mnt}"
: "${SRVDO_CACHE_TTL:=30}"
: "${SRVDO_PING_COUNT:=4}"
: "${SRVDO_CONNECT_TIMEOUT:=8}"
: "${SRVDO_DEBOUNCE:=0.4}"
: "${SRVDO_KEY:=$HOME/.ssh/id_ed25519}"
: "${SRVDO_RECONNECT:=1}"
: "${SRVDO_RECONNECT_MAX:=60}"
: "${SRVDO_STATE:=\$HOME/.srvdo}"
if [ "${#SRVDO_EXCLUDE[@]}" -eq 0 ]; then
  SRVDO_EXCLUDE=(.git node_modules __pycache__ .venv '*.pyc' .DS_Store '*.swp')
fi

# ── оформление ────────────────────────────────────────────────────────────
if [ -z "${NO_COLOR-}" ] && command -v tput >/dev/null 2>&1 \
   && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  _CB=$(tput bold); _CD=$(tput dim); _C0=$(tput sgr0)
  _CH=$(tput setaf 6); _CG=$(tput setaf 2); _CY=$(tput setaf 3); _CE=$(tput setaf 1)
else _CB=; _CD=; _C0=; _CH=; _CG=; _CY=; _CE=; fi

_srvdo_say()  { [ "${_SRVDO_QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }

# printf %-Ns считает байты, поэтому кириллица ломает выравнивание.
# Определяем один раз, умеет ли ${#s} считать символы, и добиваем пробелами сами.
_srvdo__probe=я
if [ ${#_srvdo__probe} -eq 1 ]; then
  _srvdo_dwidth() { printf '%s' "${#1}"; }
else
  # без опоры на локаль: убираем продолжающие байты UTF-8 (10xxxxxx),
  # после чего число байт равно числу символов
  _srvdo_dwidth() {
    printf '%s' "$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c)"
  }
fi
unset _srvdo__probe
_srvdo_pad() {  # текст ширина
  local n; n=$(_srvdo_dwidth "$1"); n=$(( $2 - n )); [ "$n" -lt 1 ] && n=1
  printf '%s%*s' "$1" "$n" ""
}

_srvdo_ok()   { [ "${_SRVDO_QUIET:-0}" = 1 ] || printf '%s✓%s %s\n' "$_CG" "$_C0" "$*"; }
_srvdo_warn() { printf '%s!%s %s\n' "$_CY" "$_C0" "$*" >&2; }
_srvdo_err()  { printf '%sсбой:%s %s\n' "$_CE" "$_C0" "$*" >&2; }
_srvdo_hint() { printf '  %s%s%s\n' "$_CD" "$*" "$_C0" >&2; }
_srvdo_cmd()  { printf '  %s%s%s\n' "$_CH" "$*" "$_C0" >&2; }

# ── справка ───────────────────────────────────────────────────────────────
_srvdo_h_sec() { printf '\n%s%s%s\n' "$_CB" "$1" "$_C0"; }
_srvdo_h_row() { printf '  %s%s%s %s\n' "$_CH" "$(_srvdo_pad "$1" 28)" "$_C0" "$2"; }

_srvdo_help() {
  printf '%ssrvdo%s — сервер под рукой: команды, сессии, файлы, порты.  сервер: %s%s%s\n' \
    "$_CB" "$_C0" "$_CB" "$SRVDO_HOST" "$_C0"
  printf '%sподробно о любой команде: srvdo КОМАНДА ?   ·   сценарии: srvdo examples%s\n' "$_CD" "$_C0"

  _srvdo_h_sec 'ОБЩИЕ ОПЦИИ (ставятся перед командой, сочетаются)'
  _srvdo_h_row '--alias=ИМЯ, --host=ИМЯ'   'выполнить на другом сервере'
  _srvdo_h_row '--dir=ПУТЬ'                'переопределить каталог по умолчанию'
  _srvdo_h_row '--editor=РЕД, --editor=?'  'редактор для edit (? — выбрать из установленных)'
  _srvdo_h_row '--peek=N'                  'сколько строк показывает peek'
  _srvdo_h_row '--timeout=СЕК'             'таймаут установки соединения'
  _srvdo_h_row '--exclude=ШАБЛОН'          'ещё одно исключение для rsync (можно повторять)'
  _srvdo_h_row '-n, --dry-run'             'показать, что будет сделано, но не делать'
  _srvdo_h_row '-y, --yes'                 'не спрашивать подтверждений'
  _srvdo_h_row '-q, --quiet'               'только ошибки'
  _srvdo_h_row '--no-reconnect'            'не переподключаться при обрыве'
  _srvdo_h_row '--config=ФАЙЛ'             'другой файл настроек'

  _srvdo_h_sec 'НАСТРОЙКА И ДИАГНОСТИКА'
  _srvdo_h_row 'init'                      'настроить сервер: адрес, юзер, ключ, алиас'
  _srvdo_h_row 'config [edit]'             'показать или править настройки'
  _srvdo_h_row 'hosts'                     'алиасы из ~/.ssh/config'
  _srvdo_h_row 'use ИМЯ [--save]'          'сменить сервер (для оболочки или навсегда)'
  _srvdo_h_row 'ping [ИМЯ]'                'ICMP, порт и ssh-рукопожатие по слоям'
  _srvdo_h_row 'doctor'                    'что установлено здесь и на сервере'
  _srvdo_h_row 'info, -i'                  'uptime, диск, память, сессии'
  _srvdo_h_row 'ports'                     'какие порты слушает сервер'

  _srvdo_h_sec 'СЕССИИ (живут на сервере, переживают обрыв связи)'
  _srvdo_h_row 'session, -t [ИМЯ] [КОМ…]'  'создать или подключиться'
  _srvdo_h_row 'list, -t --list'           'список сессий'
  _srvdo_h_row 'run, -d ИМЯ КОМ…'          'запустить в фоне, запомнив код возврата'
  _srvdo_h_row 'peek, -p ИМЯ'              'показать последний вывод и выйти'
  _srvdo_h_row 'attach, -a ИМЯ'            'смотреть живьём, только чтение'
  _srvdo_h_row 'send, -s ИМЯ ТЕКСТ'        'отправить строку в сессию'
  _srvdo_h_row 'wait, -w ИМЯ'              'ждать завершения + уведомление'
  _srvdo_h_row 'record, -L ИМЯ [ФАЙЛ]'     'писать вывод сессии в файл'
  _srvdo_h_row 'logs ИМЯ'                  'читать этот файл'
  _srvdo_h_row 'detach, -D ИМЯ | --all'    'отключиться от сессии, оставив её работать'
  _srvdo_h_row 'keys'                      'включить удобный выход из сессии по F12'
  _srvdo_h_row 'kill, -k ИМЯ | --all'      'удалить сессию или все'
  _srvdo_h_row 'rename, -r СТАРОЕ НОВОЕ'   'переименовать'

  _srvdo_h_sec 'ФАЙЛЫ'
  _srvdo_h_row 'push ПУТЬ [КУДА]'          'rsync на сервер'
  _srvdo_h_row 'pull ПУТЬ [КУДА]'          'rsync с сервера'
  _srvdo_h_row 'diff ПУТЬ [КУДА]'          'что изменится при push'
  _srvdo_h_row 'watch ПУТЬ [КУДА]'         'непрерывная синхронизация'
  _srvdo_h_row 'edit ПУТЬ'                 'скачать, открыть в редакторе, вернуть'
  _srvdo_h_row 'bak [ПУТЬ]'                'забрать каталог одним tar.gz'
  _srvdo_h_row 'mount / umount [КУДА]'     'sshfs'

  _srvdo_h_sec 'ПРОЧЕЕ'
  _srvdo_h_row 'tunnel [ПОРТ[:ПОРТ]]'      'проброс порта (без аргумента — выбор)'
  _srvdo_h_row 'follow, -f ПУТЬ'           'tail -f файла на сервере'
  _srvdo_h_row 'ЛЮБАЯ КОМАНДА…'            'выполнить на сервере, вывод сюда'
  printf '\n'
}

# Справка по одной команде: srvdo КОМАНДА ?
_srvdo_topic() {
  local t=$1
  printf '%s%s%s\n' "$_CB" "── srvdo $t ──" "$_C0"
  case $t in
    init) cat <<EOF
Настраивает связь с сервером с нуля и сохраняет её.

Спросит: алиас, адрес, пользователя, порт, рабочий каталог. Затем создаст
ключ (если нет), допишет блок Host в ~/.ssh/config, попросит пароль ОДИН раз
чтобы разложить ключ, предложит поставить tmux и rsync, сохранит настройки.

Пароль вводится скрыто и никуда не сохраняется. После init он не нужен.

  srvdo init
  srvdo --alias=prod init          настроить второй сервер, не тронув первый
EOF
;;
    session) cat <<EOF
Создать сессию tmux или подключиться к существующей.

Сессия живёт на сервере независимо от вашего подключения: закрыли ноутбук —
процессы внутри работают.

Выйти, НЕ закрывая сессию: Ctrl-b d (или просто F12 после srvdo keys).
Выйти снаружи: srvdo detach ИМЯ. Закрыть совсем: srvdo kill ИМЯ.

  srvdo -t AAA                     создать AAA или войти, если уже есть
  srvdo -t AAA 'npm run dev'       то же + запустить команду ПРИ СОЗДАНИИ
  srvdo -t                         выбрать из существующих (нужен fzf)
  srvdo -t --list                  таблица всех сессий
  srvdo -t --last                  вернуться в последнюю использованную
  srvdo --alias=prod -t deploy     сессия на другом сервере

Длинная форма: srvdo session AAA. Команда запускается только при создании;
для чистого старта сначала srvdo -k AAA.
При обрыве связи переподключается сам (отключить: --no-reconnect).
EOF
;;
    run) cat <<EOF
Запустить команду в фоне, не подключаясь к сессии.

Код возврата сохраняется на сервере, поэтому wait потом скажет, чем кончилось.

  srvdo -d build 'make -j4'
  srvdo run tests 'pytest -q'
  srvdo -d build 'make' && srvdo -w build     запустить и ждать с уведомлением

Смотреть ход: srvdo -p build   ·   войти внутрь: srvdo -t build
EOF
;;
    wait) cat <<EOF
Ждать, пока сессия завершится, и прислать уведомление.

Уровень уведомления зависит от результата:
  код 0        --urgency=low       «успешно за Nс»
  код ≠ 0      --urgency=critical  «код N»
  не через -d  --urgency=normal    код неизвестен

  srvdo -w build

Ctrl-C прекращает ожидание, но не саму задачу.
EOF
;;
    peek) cat <<EOF
Показать последние строки вывода сессии и сразу выйти.

  srvdo -p web
  srvdo --peek=300 -p web          больше строк
  watch -n5 'srvdo -p build'       следить со стороны

Ничего не нажимает и не мешает работе внутри сессии.
EOF
;;
    attach) cat <<EOF
Подключиться к сессии в режиме только для чтения.

Видно всё живьём, но случайное нажатие ничего не сломает. Выйти: Ctrl-b d.

  srvdo -a web
EOF
;;
    send) cat <<EOF
Отправить строку в сессию, как будто вы её напечатали.

  srvdo -s repl 'print(len(data))'
  srvdo -s build q

Работает через tmux send-keys, то есть буквально эмулирует клавиатуру.
Если сессия в этот момент не ждала ввода, строка уйдёт не туда — проверяйте
результат через srvdo -p ИМЯ.
EOF
;;
    kill) cat <<EOF
Удалить сессию вместе со всем, что в ней работает.

  srvdo -k AAA
  srvdo -k --all                   все (спросит подтверждение)
  srvdo -y -k --all                без подтверждения
  srvdo -n -k --all                только показать, что удалилось бы

Совпадение точное: srvdo -k AA не тронет AAA.
Если нужно просто выйти, не убивая — Ctrl-b d внутри сессии.
EOF
;;
    record) cat <<EOF
Писать весь вывод сессии в файл на сервере.

  srvdo -L build                   → \$HOME/tmux-build.log
  srvdo -L build /var/log/b.log    свой путь
  srvdo logs build                 читать (tail -f)

Повторный вызов выключает запись.
EOF
;;
    detach) cat <<EOF
Отключиться от сессии, не закрывая её. Всё внутри продолжает работать.

Изнутри сессии проще всего нажать Ctrl-b d — это и есть «выйти, оставив
работать». Если Ctrl-b перехватывает локальная сессия, жмите Ctrl-b b d,
либо включите однокнопочный выход: srvdo keys (тогда просто F12).

Команда нужна, когда отключиться надо СНАРУЖИ — например, сессия осталась
подключённой в закрытом терминале или на другой машине:

  srvdo detach AAA                 отцепить всех от сессии AAA
  srvdo -D AAA                     то же короткой формой
  srvdo detach --all               отцепить всех от всех сессий

Сессия и процессы внутри при этом не трогаются — сравните с srvdo kill,
который их убивает.
EOF
;;
    keys) cat <<EOF
Включить на сервере удобные клавиши в сессиях.

  srvdo keys

Добавляет в ~/.tmux.conf на сервере (в отдельный блок, с бэкапом):
  F12 или Alt-d   выйти из сессии, не закрывая её — без всяких префиксов
  колесо мыши     прокрутка вывода
  50000 строк     история прокрутки
  малая задержка  Esc не залипает

Зачем: стандартный выход Ctrl-b d конфликтует с локальной сессией, если вы
держите её и у себя. F12 идёт напрямую в дальнюю сессию, конфликта нет.

Уже открытые сессии подхватят настройки после:  srvdo 'tmux source ~/.tmux.conf'
EOF
;;
    rename) cat <<EOF
Переименовать сессию.

  srvdo -r old new

В имени нельзя ':' и '.' — ограничение tmux.
EOF
;;
    push) cat <<EOF
Отправить файл или каталог на сервер (rsync).

  srvdo push ~/proj                → \$SRVDO_DIR/proj
  srvdo push ~/proj/ /srv/app      слэш: содержимое папки, а не сама папка
  srvdo push ~/proj --exclude='*.log'
  srvdo -n push ~/proj             показать, что уедет, но не отправлять
  srvdo --alias=prod push ~/proj

Слэш на конце — самая частая ошибка. srvdo diff покажет результат заранее.
Исключения по умолчанию: ${SRVDO_EXCLUDE[*]}
EOF
;;
    pull) cat <<EOF
Забрать файл или каталог с сервера.

  srvdo pull /root/results.csv         в текущий каталог
  srvdo pull /root/logs ~/Desktop
EOF
;;
    diff) cat <<EOF
Показать, что изменится при push, ничего не меняя.

  srvdo diff ~/proj

Читается так: '<' — уедет на сервер, '*deleting' — будет удалено ТАМ.
Учитывает --delete, как и watch, поэтому запуск перед push спасает от
неожиданных удалений.
EOF
;;
    watch) cat <<EOF
Держать локальный каталог и серверный синхронизированными непрерывно.

  srvdo watch ~/proj
  srvdo watch ~/proj /srv/app

Локальный inotifywait ловит изменения и запускает rsync с паузой
${SRVDO_DEBOUNCE}с. Синхронизация ОДНОСТОРОННЯЯ (локально → сервер) и с --delete:
удалили файл у себя — исчезнет и там. Для двусторонней смотрите Syncthing.

Нужен пакет inotify-tools.
EOF
;;
    edit) cat <<EOF
Правка удалённого файла своим редактором: скачать → открыть → вернуть.

  srvdo edit /etc/nginx/nginx.conf
  srvdo --editor=vim edit /etc/hosts
  srvdo --editor=? edit /etc/hosts     выбрать редактор из установленных

Редактор берётся так: --editor= → SRVDO_EDITOR → \$VISUAL → \$EDITOR →
интерактивный выбор (и предложит запомнить). Для VS Code сам добавляет --wait.

Если ничего не изменили, отправки не будет. Перед перезаписью на сервере
остаётся ФАЙЛ.srvdo-bak. Если отправить не удалось, скажет, где ваша правка.
EOF
;;
    bak) cat <<EOF
Снять каталог с сервера одним архивом себе на диск.

  srvdo bak                        каталог по умолчанию (\$SRVDO_DIR)
  srvdo bak /srv/data              → ./data-2026-07-24-1830.tar.gz
EOF
;;
    mount|umount) cat <<EOF
Смонтировать серверный каталог локально через sshfs.

  srvdo mount                      \$SRVDO_DIR → $SRVDO_MOUNT_BASE/\$АЛИАС
  srvdo mount ~/serv               своя точка
  srvdo umount

Удобно, когда правок мало и не хочется думать о синхронизации. Медленно при
плохой сети и не работает офлайн — тогда лучше watch. Нужен пакет sshfs.
EOF
;;
    tunnel) cat <<EOF
Пробросить порт сервера на свой localhost.

  srvdo tunnel 8080                localhost:8080 → сервер:8080
  srvdo tunnel 3000:8080           localhost:3000 → сервер:8080
  srvdo tunnel                     выбрать из слушающих портов (нужен fzf)

Что слушается на сервере: srvdo ports. Закрыть: Ctrl-C.
Занятость локального порта проверяется заранее.
EOF
;;
    ping) cat <<EOF
Проверить связь тремя слоями по очереди.

  srvdo ping
  srvdo ping prod

  ICMP ✗  порт ✗   сервер выключен, адрес неверный или всё режет файрвол
  ICMP ✗  порт ✓   норма: ICMP просто закрыт у провайдера
  ICMP ✓  порт ✗   сервер жив, ssh не на этом порту → srvdo config
  порт ✓  SSH ✗    сеть в порядке, дело в доступе → srvdo init
EOF
;;
    use) cat <<EOF
Переключиться на другой сервер.

  srvdo use prod                   только в этой оболочке
  srvdo use prod --save            запомнить как основной
  srvdo hosts                      какие алиасы есть

Разово, без переключения, удобнее общей опцией:
  srvdo --alias=prod -t deploy
EOF
;;
    config) cat <<EOF
Показать или править настройки ($SRVDO_CONFIG).

  srvdo config                     показать текущие значения
  srvdo config edit                открыть в редакторе и перечитать

Любую переменную можно переопределить на один вызов:
  SRVDO_PEEK=300 srvdo -p web
  srvdo --peek=300 -p web
EOF
;;
    logs) cat <<EOF
Читать файл, в который пишет запись сессии (srvdo -L).

  srvdo logs build
EOF
;;
    ports) cat <<EOF
Показать, какие порты слушает сервер (ss, при отсутствии — netstat).

  srvdo ports
  srvdo tunnel                     пробросить один из них сюда
EOF
;;
    info) cat <<EOF
Сводка о сервере: uptime, свободное место, память, список сессий.

  srvdo -i
  srvdo --alias=prod -i
EOF
;;
    follow) cat <<EOF
Следить за файлом на сервере (tail -f).

  srvdo -f /var/log/nginx/error.log

Существование файла проверяется заранее.
EOF
;;
    doctor) cat <<EOF
Проверить окружение с обеих сторон: ssh, rsync, tmux, fzf, sshfs,
inotifywait, наличие ключа, блока Host, мультиплексирования, токена на сервере.

  srvdo doctor
EOF
;;
    hosts) cat <<EOF
Перечислить алиасы серверов из ~/.ssh/config.

  srvdo hosts
EOF
;;
    *) printf 'нет отдельной справки по «%s».\n' "$t"
       printf 'общая справка: srvdo -h   ·   сценарии: srvdo examples\n' ;;
  esac
  printf '\n'
}

_srvdo_examples() {
  cat <<EOF
${_CB}── первый запуск ──${_C0}
  srvdo init                       настроить (пароль спросит один раз)
  srvdo ping                       проверить связь
  srvdo doctor                     проверить, что всё установлено

${_CB}── залить проект и работать над ним ──${_C0}
  srvdo diff ~/proj                посмотреть, что уедет и что удалится
  srvdo push ~/proj                залить
  srvdo watch ~/proj               держать синхронизированным

${_CB}── долгая задача с уведомлением ──${_C0}
  srvdo -d build 'make -j4'
  srvdo -w build                   уведомление critical, если код не 0
  srvdo -p build                   посмотреть вывод

${_CB}── dev-сервер на VPS ──${_C0}
  srvdo -d web 'npm run dev'
  srvdo ports                      убедиться, что порт слушается
  srvdo tunnel                     выбрать и пробросить сюда

${_CB}── два сервера одновременно ──${_C0}
  srvdo --alias=prod -i            сводка по prod, не переключаясь
  srvdo --alias=prod push ~/proj
  srvdo use prod --save            сделать основным

${_CB}── разное ──${_C0}
  srvdo --editor=vim edit /etc/nginx/nginx.conf
  srvdo bak /srv/data              архив каталога себе
  srvdo -n push ~/proj             репетиция без изменений
EOF
}

# ── служебное ─────────────────────────────────────────────────────────────
_srvdo_q() { printf '%q' "$1"; }
_srvdo_excl() { local p; for p in "${SRVDO_EXCLUDE[@]}"; do printf -- '--exclude\n%s\n' "$p"; done; }
_srvdo_rsync() {
  local -a e; mapfile -t e < <(_srvdo_excl)
  [ "${_SRVDO_DRY:-0}" = 1 ] && e+=(--dry-run)
  rsync "${e[@]}" "$@"
}

_srvdo_resolve() {
  ssh -G "${1:-$SRVDO_HOST}" 2>/dev/null \
    | awk '/^hostname /{h=$2} /^port /{p=$2} /^user /{u=$2} END{print u" "h" "p}'
}

_srvdo_ssh_config_has() {
  grep -qiE "^[[:space:]]*Host[[:space:]]+([^#]*[[:space:]])?$1([[:space:]]|$)" \
    "$HOME/.ssh/config" 2>/dev/null
}

_srvdo_diag() {
  local host=${1:-$SRVDO_HOST}
  printf '\n' >&2
  _srvdo_err "не удалось подключиться к «$host». Что проверить:"
  [ -f "$SRVDO_CONFIG" ] || { _srvdo_hint "настройки не созданы:"; _srvdo_cmd "srvdo init"; }
  if ! _srvdo_ssh_config_has "$host"; then
    _srvdo_hint "в ~/.ssh/config нет блока «Host $host»"
    _srvdo_cmd "srvdo hosts     # какие алиасы есть"
    _srvdo_cmd "srvdo init      # добавить этот"
  else
    local u h p; read -r u h p < <(_srvdo_resolve "$host")
    _srvdo_hint "алиас разворачивается в $u@$h:$p"
    _srvdo_hint "где именно рвётся, покажет:"
    _srvdo_cmd "srvdo ping"
  fi
  [ -f "$SRVDO_KEY" ] || _srvdo_hint "ключа $SRVDO_KEY нет — его создаст srvdo init"
}

_srvdo_ssh() {
  local tty=0
  [ "${1-}" = "--tty" ] && { tty=1; shift; }
  local rc
  if [ $tty -eq 1 ]; then ssh -t "$SRVDO_HOST" "$@"; rc=$?
  else ssh "$SRVDO_HOST" "$@"; rc=$?; fi
  [ $rc -eq 255 ] && _srvdo_diag
  return $rc
}

_srvdo_require_tmux() {
  [ -n "${_SRVDO_TMUX_OK-}" ] && return 0
  if ssh -o ConnectTimeout="$SRVDO_CONNECT_TIMEOUT" "$SRVDO_HOST" 'command -v tmux >/dev/null' 2>/dev/null; then
    _SRVDO_TMUX_OK=1; return 0
  fi
  local rc=$?
  [ $rc -eq 255 ] && { _srvdo_diag; return 1; }
  _srvdo_err "на сервере не установлен tmux — без него сессии не работают"
  _srvdo_cmd "srvdo apt-get install -y tmux"
  return 1
}

_srvdo_valid_name() {
  case ${1-} in
    "")     _srvdo_err "имя сессии не указано"; _srvdo_cmd "srvdo -t dev"; return 1 ;;
    *[:.]*) _srvdo_err "в имени сессии нельзя ':' и '.' — tmux их не принимает"
            _srvdo_hint "попробуйте: ${1//[:.]/-}"; return 1 ;;
    -*)     _srvdo_err "«$1» похоже на флаг, а не на имя сессии"
            _srvdo_hint "порядок: srvdo [общие опции] -t ИМЯ [команда]"; return 1 ;;
  esac
}

_srvdo_have()  { ssh "$SRVDO_HOST" "tmux has-session -t=$(_srvdo_q "$1")" 2>/dev/null; }
_srvdo_names() { ssh -o BatchMode=yes "${1:-$SRVDO_HOST}" 'tmux ls -F "#{session_name}"' 2>/dev/null; }

_srvdo_need() {
  _srvdo_valid_name "$1" || return 1
  _srvdo_require_tmux || return 1
  _srvdo_have "$1" && return 0
  _srvdo_err "сессии «$1» нет"
  local live; live=$(_srvdo_names)
  if [ -n "$live" ]; then
    _srvdo_hint "живые: $(echo "$live" | paste -sd', ')"
    _srvdo_cmd "srvdo -t --list"
  else
    _srvdo_hint "на сервере нет ни одной сессии"
    _srvdo_cmd "srvdo -t $1 <команда>"
  fi
  return 1
}

_srvdo_wrap_exit() {
  local name=$1; shift
  local b64; b64=$(printf '%s' "$*" | base64 | tr -d '\n')
  printf '%s' "mkdir -p $SRVDO_STATE; ( eval \"\$(printf %s $b64 | base64 -d)\" ); \
c=\$?; printf '%s' \$c > $SRVDO_STATE/exit-$name; \
[ \$c -eq 0 ] || { echo; echo \"[srvdo] команда завершилась с кодом \$c\"; sleep 5; }"
}

_srvdo_exit_code() { ssh "$SRVDO_HOST" "cat $SRVDO_STATE/exit-$(_srvdo_q "$1") 2>/dev/null" 2>/dev/null; }

_srvdo_notify() {
  local urgency=$1 title=$2 body=$3
  command -v notify-send >/dev/null && \
    notify-send --urgency="$urgency" --app-name=srvdo "$title" "$body"
  printf '\a'
}

_srvdo_confirm() {
  [ "${_SRVDO_YES:-0}" = 1 ] && return 0
  local yn; read -r -p "$1 (y/N): " yn
  case $yn in [yYдД]*) return 0 ;; *) _srvdo_say "отменено"; return 1 ;; esac
}

# Выбор редактора: флаг → конфиг → $VISUAL → $EDITOR → меню установленных
_srvdo_editor() {
  local want=${_SRVDO_EDITOR_FLAG:-}
  if [ -n "$want" ] && [ "$want" != '?' ]; then printf '%s' "$want"; return; fi
  if [ "$want" != '?' ]; then
    for e in "$SRVDO_EDITOR" "$VISUAL" "$EDITOR"; do
      [ -n "$e" ] && { printf '%s' "$e"; return; }
    done
  fi
  local cands=(nvim vim micro nano helix hx emacs kak code codium subl gedit kate)
  local found=() c
  for c in "${cands[@]}"; do command -v "$c" >/dev/null 2>&1 && found+=("$c"); done
  if [ ${#found[@]} -eq 0 ]; then
    _srvdo_err "не нашёл ни одного редактора"
    _srvdo_hint "задайте явно: srvdo --editor=ваш-редактор edit ФАЙЛ"
    return 1
  fi
  local pick
  if command -v fzf >/dev/null 2>&1; then
    pick=$(printf '%s\n' "${found[@]}" | fzf --height 40% --reverse --prompt 'редактор> ')
  else
    printf 'Чем открыть?\n' >&2
    local i=1
    for c in "${found[@]}"; do printf '  %d) %s\n' "$i" "$c" >&2; i=$((i+1)); done
    local n; read -r -p "номер [1]: " n; n=${n:-1}
    case $n in ''|*[!0-9]*) n=1 ;; esac
    pick=${found[$((n-1))]}
  fi
  [ -n "$pick" ] || return 1
  if [ -f "$SRVDO_CONFIG" ] && ! grep -q '^SRVDO_EDITOR=' "$SRVDO_CONFIG"; then
    if _srvdo_confirm "запомнить $pick как редактор по умолчанию?"; then
      echo "SRVDO_EDITOR=$pick" >>"$SRVDO_CONFIG"; SRVDO_EDITOR=$pick
    fi
  fi
  printf '%s' "$pick"
}

_srvdo_run_editor() {  # редактор + файл, с --wait для графических
  local ed=$1 file=$2
  case $ed in
    code|code-insiders|codium|subl|sublime_text) "$ed" --wait "$file" ;;
    *) $ed "$file" ;;
  esac
}

# ── init ──────────────────────────────────────────────────────────────────
_srvdo_ask() {
  local q=$1 def=$2 ans
  if [ -n "$def" ]; then read -r -p "$q [$def]: " ans; else read -r -p "$q: " ans; fi
  printf '%s' "${ans:-$def}"
}

_srvdo_ssh_config_drop() {
  local alias=$1 cfg=$HOME/.ssh/config bak
  [ -f "$cfg" ] || return 0
  bak="$cfg.bak.$(date +%Y%m%d%H%M%S)"; cp "$cfg" "$bak"
  _srvdo_say "  бэкап конфига: $bak"
  awk -v a="$alias" 'BEGIN{IGNORECASE=1; skip=0}
    /^[[:space:]]*Host[[:space:]]/ { skip = ($0 ~ "(^|[[:space:]])" a "([[:space:]]|$)") ? 1 : 0 }
    !skip' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  chmod 600 "$cfg"
}

_srvdo_init() {
  printf '%s── настройка srvdo ──%s\n' "$_CB" "$_C0"
  local alias addr user port dir cfg=$HOME/.ssh/config

  alias=$(_srvdo_ask "Алиас (как будете называть сервер)" "${SRVDO_HOST:-srv}")
  case $alias in ""|*[[:space:]*?]*)
    _srvdo_err "алиас должен быть одним словом без пробелов и '*'"; return 2 ;; esac
  addr=$(_srvdo_ask "Адрес (IP или домен)" "")
  [ -n "$addr" ] || { _srvdo_err "адрес обязателен — без него подключаться некуда"; return 2; }
  user=$(_srvdo_ask "Пользователь" "root")
  port=$(_srvdo_ask "Порт SSH" "22")
  case $port in ''|*[!0-9]*) _srvdo_err "порт должен быть числом, получено «$port»"; return 2 ;; esac
  if [ "$user" = root ]; then dir=$(_srvdo_ask "Рабочий каталог на сервере" "/root")
  else dir=$(_srvdo_ask "Рабочий каталог на сервере" "/home/$user"); fi

  printf '\n'
  if [ ! -f "$SRVDO_KEY" ]; then
    _srvdo_say "Ключа $SRVDO_KEY нет, создаю (Enter — без пароля на ключ):"
    ssh-keygen -t ed25519 -f "$SRVDO_KEY" -C "srvdo@$(hostname)" || {
      _srvdo_err "ssh-keygen не справился"; return 1; }
  else _srvdo_ok "ключ уже есть: $SRVDO_KEY"; fi

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if _srvdo_ssh_config_has "$alias"; then
    if _srvdo_confirm "В ~/.ssh/config уже есть Host $alias. Заменить?"; then
      _srvdo_ssh_config_drop "$alias"
    else _srvdo_say "  оставляю существующий блок"; fi
  fi
  if ! _srvdo_ssh_config_has "$alias"; then
    cat >>"$cfg" <<EOF

Host $alias
    HostName $addr
    User $user
    Port $port
    IdentityFile $SRVDO_KEY
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
EOF
    chmod 600 "$cfg"
    _srvdo_ok "в ~/.ssh/config добавлен Host $alias"
  fi

  printf '\n'
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$alias" true 2>/dev/null; then
    _srvdo_ok "вход по ключу уже работает — пароль не нужен"
  else
    _srvdo_say "Нужен пароль от $user@$addr — один раз, чтобы положить туда ключ."
    _srvdo_say "Он не сохраняется ни в файлы, ни в историю команд."
    local copied=1
    if command -v sshpass >/dev/null; then
      local pw; read -r -s -p "Пароль (Enter — ввести вручную далее): " pw; printf '\n'
      if [ -n "$pw" ]; then SSHPASS=$pw sshpass -e ssh-copy-id -i "$SRVDO_KEY.pub" "$alias"; copied=$?; unset pw
      else ssh-copy-id -i "$SRVDO_KEY.pub" "$alias"; copied=$?; fi
    else ssh-copy-id -i "$SRVDO_KEY.pub" "$alias"; copied=$?; fi
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$alias" true 2>/dev/null; then
      _srvdo_ok "вход по ключу работает"
    else
      _srvdo_err "по ключу зайти не удалось (ssh-copy-id вернул $copied). Причины:"
      _srvdo_hint "неверный пароль"
      _srvdo_hint "сервер запрещает вход root по ssh → используйте обычного юзера"
      _srvdo_hint "PasswordAuthentication no → ключ придётся положить вручную"
      _srvdo_cmd "srvdo ping $alias"
    fi
  fi

  if _srvdo_confirm "Поставить на сервере tmux и rsync?"; then
    ssh -t "$alias" '
      if command -v tmux >/dev/null && command -v rsync >/dev/null; then echo "уже есть"
      elif command -v apt-get >/dev/null; then
        (apt-get update -qq && apt-get install -y tmux rsync) 2>/dev/null \
          || (sudo apt-get update -qq && sudo apt-get install -y tmux rsync)
      elif command -v dnf >/dev/null; then sudo dnf install -y tmux rsync
      elif command -v apk >/dev/null; then sudo apk add tmux rsync
      else echo "не понял пакетный менеджер — поставьте tmux и rsync руками" >&2; fi'
  fi

  mkdir -p "$(dirname "$SRVDO_CONFIG")"
  cat >"$SRVDO_CONFIG" <<EOF
# настройки srvdo — правится руками или через: srvdo config edit
SRVDO_HOST=$alias
SRVDO_DIR=$dir
SRVDO_KEY=$SRVDO_KEY
SRVDO_EDITOR=$SRVDO_EDITOR
SRVDO_PEEK=$SRVDO_PEEK
SRVDO_MOUNT_BASE=$SRVDO_MOUNT_BASE
SRVDO_CACHE_TTL=$SRVDO_CACHE_TTL
SRVDO_PING_COUNT=$SRVDO_PING_COUNT
SRVDO_CONNECT_TIMEOUT=$SRVDO_CONNECT_TIMEOUT
SRVDO_DEBOUNCE=$SRVDO_DEBOUNCE
SRVDO_RECONNECT=$SRVDO_RECONNECT
SRVDO_EXCLUDE=($(printf '%q ' "${SRVDO_EXCLUDE[@]}"))
EOF
  SRVDO_HOST=$alias; SRVDO_DIR=$dir
  printf '\n'; _srvdo_ok "готово. Настройки: $SRVDO_CONFIG"
  _srvdo_cmd "srvdo ping   ·   srvdo doctor   ·   srvdo examples"
}

# ── ping ──────────────────────────────────────────────────────────────────
_srvdo_ping() {
  local host=${1:-$SRVDO_HOST} u h p tmp
  read -r u h p < <(_srvdo_resolve "$host")
  if { [ -z "$h" ] || [ "$h" = "$host" ]; } && ! _srvdo_ssh_config_has "$host"; then
    _srvdo_err "алиас «$host» не описан в ~/.ssh/config"
    _srvdo_cmd "srvdo hosts     # что есть"
    _srvdo_cmd "srvdo init      # добавить"
    return 1
  fi
  printf '%s── %s → %s@%s:%s ──%s\n' "$_CB" "$host" "$u" "$h" "$p" "$_C0"
  tmp=$(mktemp)

  printf '%s' "$(_srvdo_pad "ICMP" 16)"
  if ping -c "$SRVDO_PING_COUNT" -W 2 "$h" >"$tmp" 2>&1; then
    printf '%s✓%s %s ms сред., потерь %s\n' "$_CG" "$_C0" \
      "$(awk -F'/' '/rtt|round-trip/{print $5}' "$tmp")" \
      "$(awk '{for(i=1;i<=NF;i++) if($i ~ /%$/){print $i; exit}}' "$tmp")"
  else
    printf '%s✗%s нет ответа %s(обычно ICMP просто закрыт — смотрите ниже)%s\n' \
      "$_CY" "$_C0" "$_CD" "$_C0"
  fi
  rm -f "$tmp"

  printf '%s' "$(_srvdo_pad "порт $p" 16)"
  local t0 t1; t0=$(date +%s%N)
  if timeout 5 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
    t1=$(date +%s%N); printf '%s✓%s открыт (%d ms)\n' "$_CG" "$_C0" $(( (t1-t0)/1000000 ))
  else
    printf '%s✗%s недоступен\n' "$_CE" "$_C0"
    _srvdo_hint "сервер выключен, адрес неверный, ssh на другом порту или файрвол"
    _srvdo_cmd "srvdo config    # проверить адрес и порт"
    return 1
  fi

  printf '%s' "$(_srvdo_pad "SSH" 16)"
  t0=$(date +%s%N)
  if ssh -o BatchMode=yes -o ConnectTimeout="$SRVDO_CONNECT_TIMEOUT" "$host" true 2>/dev/null; then
    t1=$(date +%s%N); printf '%s✓%s вход по ключу, %d ms\n' "$_CG" "$_C0" $(( (t1-t0)/1000000 ))
  else
    printf '%s✗%s по ключу не пускает\n' "$_CE" "$_C0"
    _srvdo_hint "сеть в порядке, дело в доступе: ключ не разложен или не тот юзер"
    _srvdo_cmd "srvdo init"
    return 1
  fi

  printf '%s%s\n' "$(_srvdo_pad "аптайм" 16)" "$(ssh "$host" 'uptime -p 2>/dev/null || uptime')"
  printf '%s%s\n' "$(_srvdo_pad "сессии tmux" 16)" "$(ssh "$host" 'tmux ls 2>/dev/null | wc -l' | sed 's/^0$/нет/')"
}

# ── основная функция ──────────────────────────────────────────────────────
srvdo() {
  # локальные копии: общие опции действуют только на этот вызов
  local SRVDO_HOST=$SRVDO_HOST SRVDO_DIR=$SRVDO_DIR SRVDO_PEEK=$SRVDO_PEEK
  local SRVDO_CONNECT_TIMEOUT=$SRVDO_CONNECT_TIMEOUT SRVDO_RECONNECT=$SRVDO_RECONNECT
  local SRVDO_EXCLUDE=("${SRVDO_EXCLUDE[@]}")
  local _SRVDO_DRY=0 _SRVDO_YES=0 _SRVDO_QUIET=0 _SRVDO_EDITOR_FLAG=

  # ── фаза 1: общие опции ────────────────────────────────────────────────
  while [ $# -gt 0 ]; do
    case $1 in
      --alias=*|--host=*|--server=*) SRVDO_HOST=${1#*=} ;;
      --alias|--host|--server)       SRVDO_HOST=${2-}; shift
                                     [ -n "$SRVDO_HOST" ] || { _srvdo_err "--alias без значения"; return 2; } ;;
      --dir=*)      SRVDO_DIR=${1#*=} ;;
      --dir)        SRVDO_DIR=${2-}; shift ;;
      --editor=*)   _SRVDO_EDITOR_FLAG=${1#*=} ;;
      --editor)     _SRVDO_EDITOR_FLAG=${2-}; shift ;;
      --peek=*)     SRVDO_PEEK=${1#*=} ;;
      --timeout=*)  SRVDO_CONNECT_TIMEOUT=${1#*=} ;;
      --exclude=*)  SRVDO_EXCLUDE+=("${1#*=}") ;;
      --exclude)    SRVDO_EXCLUDE+=("${2-}"); shift ;;
      --config=*)   SRVDO_CONFIG=${1#*=}; [ -f "$SRVDO_CONFIG" ] && . "$SRVDO_CONFIG" ;;
      --no-reconnect) SRVDO_RECONNECT=0 ;;
      -n|--dry-run) _SRVDO_DRY=1 ;;
      -y|--yes)     _SRVDO_YES=1 ;;
      -q|--quiet)   _SRVDO_QUIET=1 ;;
      --no-color)   _CB=; _CD=; _C0=; _CH=; _CG=; _CY=; _CE= ;;
      --) shift; break ;;
      *) break ;;
    esac
    shift
  done

  # ── фаза 2: команда к каноническому виду ───────────────────────────────
  local cmd=${1-}; [ $# -gt 0 ] && shift
  case $cmd in
    -t|--tmux|--session|session|attach-or-create) cmd=session ;;
    -d|--detach|--run|run)          cmd=run ;;
    -a|--attach|attach|--readonly)  cmd=attach ;;
    -p|--peek|peek)                 cmd=peek ;;
    -s|--send|send)                 cmd=send ;;
    -w|--wait|wait)                 cmd=wait ;;
    -L|--record|record)             cmd=record ;;
    -D|--detach-client|detach)      cmd=detach ;;
    -k|--kill|kill)                 cmd=kill ;;
    -r|--rename|rename)             cmd=rename ;;
    -i|--info|info|status)          cmd=info ;;
    -f|--follow|follow|tail)        cmd=follow ;;
    -l|--list|list|ls)              cmd=list ;;
    cache-clear|--clear-cache)      cmd=cache_clear ;;
    -h|--help|help|'?')             cmd=help ;;
    --version) printf 'srvdo 3.0\n'; return 0 ;;
  esac

  # ── фаза 3: справка по команде ──────────────────────────────────────────
  if [ "$cmd" = help ]; then
    if [ -n "${1-}" ]; then _srvdo_topic "$(srvdo_canon "$1")"; else _srvdo_help; fi
    return 0
  fi
  case ${1-} in
    '?'|--help|-h) _srvdo_topic "$cmd"; return 0 ;;
  esac

  # ── фаза 4: выполнение ──────────────────────────────────────────────────
  local host=$SRVDO_HOST
  case $cmd in
    examples) _srvdo_examples ;;
    cache_clear) srvdo_cache_clear; _srvdo_ok "кэш подсказок сброшен" ;;
    init)     _srvdo_init ;;
    ping)     _srvdo_ping "${1:-$host}" ;;

    config)
      if [ "${1-}" = edit ]; then
        mkdir -p "$(dirname "$SRVDO_CONFIG")"; touch "$SRVDO_CONFIG"
        local ed; ed=$(_srvdo_editor) || return 1
        _srvdo_run_editor "$ed" "$SRVDO_CONFIG" && . "$SRVDO_CONFIG" && _srvdo_ok "перечитано"
      else
        printf '%sфайл:%s %s%s\n' "$_CB" "$_C0" "$SRVDO_CONFIG" \
          "$([ -f "$SRVDO_CONFIG" ] || printf '   (ещё нет — srvdo init)')"
        local u h p; read -r u h p < <(_srvdo_resolve "$host")
        local k v
        while read -r k v; do
          printf '  %s%s%s %s\n' "$_CH" "$(_srvdo_pad "$k" 22)" "$_C0" "$v"
        done <<CFGEOF
SRVDO_HOST $host → $u@$h:$p
SRVDO_DIR $SRVDO_DIR
SRVDO_KEY $SRVDO_KEY
SRVDO_EDITOR ${SRVDO_EDITOR:-(не задан → \$EDITOR или выбор)}
SRVDO_PEEK $SRVDO_PEEK
SRVDO_MOUNT_BASE $SRVDO_MOUNT_BASE
SRVDO_CACHE_TTL $SRVDO_CACHE_TTL
SRVDO_PING_COUNT $SRVDO_PING_COUNT
SRVDO_CONNECT_TIMEOUT $SRVDO_CONNECT_TIMEOUT
SRVDO_DEBOUNCE $SRVDO_DEBOUNCE
SRVDO_RECONNECT $SRVDO_RECONNECT
SRVDO_EXCLUDE ${SRVDO_EXCLUDE[*]}
CFGEOF
      fi ;;

    hosts)
      local a; a=$(_srvdo_aliases)
      [ -n "$a" ] || { _srvdo_err "в ~/.ssh/config нет ни одного Host"; _srvdo_cmd "srvdo init"; return 1; }
      echo "$a" | sed 's/^/  /'
      printf '  %s(сейчас: %s)%s\n' "$_CD" "$host" "$_C0" ;;

    use)
      local a=${1-}
      [ -n "$a" ] || { _srvdo_err "укажите алиас"; srvdo hosts >&2; return 2; }
      if ! _srvdo_ssh_config_has "$a"; then _srvdo_err "в ~/.ssh/config нет Host $a"; srvdo hosts >&2; return 1; fi
      if [ "${2-}" = --save ]; then
        mkdir -p "$(dirname "$SRVDO_CONFIG")"; touch "$SRVDO_CONFIG"
        if grep -q '^SRVDO_HOST=' "$SRVDO_CONFIG"; then sed -i "s|^SRVDO_HOST=.*|SRVDO_HOST=$a|" "$SRVDO_CONFIG"
        else echo "SRVDO_HOST=$a" >>"$SRVDO_CONFIG"; fi
        _srvdo_ok "основной сервер теперь $a"
      else
        # SRVDO_HOST внутри функции локальный, поэтому меняем именно глобальный
        declare -g SRVDO_HOST="$a"
        _srvdo_say "переключился на $a (в этой оболочке; --save чтобы запомнить)"
      fi ;;

    list)
      _srvdo_require_tmux || return 1
      local out
      out=$(ssh "$host" "tmux list-sessions -F '#{session_name}|#{session_windows} окон|#{?session_attached,● подключена,○ отключена}|#{t/f/%d.%m %H:%M:session_created}' 2>/dev/null")
      if [ -z "$out" ]; then _srvdo_say "сессий нет"; _srvdo_cmd "srvdo -t ИМЯ"
      else echo "$out" | column -t -s'|'; fi
      # заодно освежаем кэш для Tab
      _srvdo_names >"${TMPDIR:-/tmp}/.srvdo-$host-$UID" 2>/dev/null ;;

    session)
      case ${1-} in
        --list|-l|list) shift; srvdo list "$@"; return ;;
        --last)
          _srvdo_require_tmux || return 1
          _srvdo_ssh --tty 'n=$(tmux ls -F "#{session_last_attached} #{session_name}" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2);
                            [ -n "$n" ] && tmux attach -t "$n" || echo "сессий нет"'
          return ;;
        "")
          _srvdo_require_tmux || return 1
          local picked
          if command -v fzf >/dev/null; then picked=$(_srvdo_names | fzf --height 40% --reverse --prompt 'сессия> ')
          else _srvdo_err "укажите имя сессии"; _srvdo_cmd "srvdo -t dev"
               _srvdo_hint "поставьте fzf, и «srvdo -t» без имени будет предлагать выбор"; return 2; fi
          [ -n "$picked" ] || return 1
          set -- "$picked" ;;
      esac
      _srvdo_valid_name "$1" || return 1
      _srvdo_require_tmux || return 1
      local name=$1; shift
      if [ $# -gt 0 ] && _srvdo_have "$name"; then
        _srvdo_warn "сессия «$name» уже работает — подключаюсь, команду не запускаю"
        _srvdo_cmd "srvdo -k $name && srvdo -t $name $*"
      fi
      local c n=0
      if [ $# -gt 0 ]; then c="tmux new-session -A -s $(_srvdo_q "$name") -- $*"
      else c="tmux new-session -A -s $(_srvdo_q "$name")"; fi
      while :; do
        ssh -t "$host" "$c"; local rc=$?
        [ $rc -ne 255 ] && return $rc
        if [ "$SRVDO_RECONNECT" != 1 ] || [ $n -ge "$SRVDO_RECONNECT_MAX" ]; then _srvdo_diag; return $rc; fi
        n=$((n+1)); printf '\rсвязь оборвалась, переподключаюсь (%d)… ' "$n" >&2; sleep 2
      done ;;

    run)
      local name=${1-}; _srvdo_valid_name "$name" || return 1; shift
      [ $# -gt 0 ] || { _srvdo_err "нужна команда"; _srvdo_cmd "srvdo -d build 'make -j4'"; return 2; }
      _srvdo_require_tmux || return 1
      if _srvdo_have "$name"; then _srvdo_err "сессия «$name» уже занята"; _srvdo_cmd "srvdo -k $name"; return 1; fi
      if [ "$_SRVDO_DRY" = 1 ]; then _srvdo_say "запустил бы в сессии «$name»: $*"; return 0; fi
      _srvdo_ssh "tmux new-session -d -s $(_srvdo_q "$name") -- bash -lc $(_srvdo_q "$(_srvdo_wrap_exit "$name" "$@")")" \
        && { _srvdo_ok "в фоне: $name"; _srvdo_cmd "srvdo -p $name   ·   srvdo -w $name"; } ;;

    attach) _srvdo_need "${1-}" || return 1
            _srvdo_say "(только чтение; выйти — Ctrl-b d)"
            _srvdo_ssh --tty "tmux attach -r -t=$(_srvdo_q "$1")" ;;

    peek)   _srvdo_need "${1-}" || return 1
            _srvdo_ssh "tmux capture-pane -p -S -$SRVDO_PEEK -t=$(_srvdo_q "$1")" ;;

    send)
      local n=${1-}; _srvdo_need "$n" || return 1; shift
      [ $# -gt 0 ] || { _srvdo_err "нужен текст"; _srvdo_cmd "srvdo -s repl 'print(1)'"; return 2; }
      if [ "$_SRVDO_DRY" = 1 ]; then _srvdo_say "отправил бы в «$n»: $*"; return 0; fi
      _srvdo_ssh "tmux send-keys -t=$(_srvdo_q "$n") $(_srvdo_q "$*") Enter" && {
        _srvdo_ok "→ $n: $*"
        _srvdo_say "  если сессия не ждала ввода, строка могла уйти не туда: srvdo -p $n"; } ;;

    wait)
      local n=${1-}; _srvdo_need "$n" || return 1
      _srvdo_say "жду «$n»… (Ctrl-C — перестать ждать; задача продолжит работать)"
      local t0=$SECONDS
      while _srvdo_have "$n"; do sleep 5; done
      local dur=$((SECONDS-t0)) code; code=$(_srvdo_exit_code "$n")
      if [ -z "$code" ]; then
        _srvdo_say "«$n» закрылась за ${dur}с (код неизвестен — запускалась не через -d)"
        _srvdo_notify normal "srvdo: $n" "сессия закрылась (${dur}с)"
      elif [ "$code" = 0 ]; then
        _srvdo_ok "«$n» успешно, ${dur}с"
        _srvdo_notify low "srvdo: $n ✓" "успешно за ${dur}с"
      else
        _srvdo_err "«$n» завершилась с кодом $code, ${dur}с"; _srvdo_cmd "srvdo -p $n"
        _srvdo_notify critical "srvdo: $n ✗" "код $code, ${dur}с"
      fi ;;

    record)
      local n=${1-}; _srvdo_need "$n" || return 1
      local f=${2:-\$HOME/tmux-$n.log}
      _srvdo_ssh "tmux pipe-pane -o -t=$(_srvdo_q "$n") \"cat >> $f\"" \
        && { _srvdo_ok "вывод «$n» → $f"; _srvdo_cmd "srvdo logs $n   ·   повторный -L выключит"; } ;;

    logs) local n=${1-}; [ -n "$n" ] || { _srvdo_err "укажите имя сессии"; return 2; }
          _srvdo_ssh --tty "f=\$HOME/tmux-$n.log; [ -f \$f ] && tail -f \$f || { echo \"файла \$f нет — включите: srvdo -L $n\" >&2; exit 1; }" ;;

    detach)
      _srvdo_require_tmux || return 1
      if [ "${1-}" = --all ]; then
        [ "$_SRVDO_DRY" = 1 ] && { _srvdo_say "отцепил бы всех от всех сессий"; return 0; }
        _srvdo_ssh 'n=$(tmux list-clients -F "#{client_tty}" 2>/dev/null | wc -l);
                    [ "$n" -gt 0 ] || { echo "никто не подключён"; exit 0; }
                    tmux list-clients -F "#{client_tty}" | while read -r t; do tmux detach-client -t "$t"; done;
                    echo "отцеплено клиентов: $n"'
        return
      fi
      _srvdo_need "${1-}" || return 1
      [ "$_SRVDO_DRY" = 1 ] && { _srvdo_say "отцепил бы всех от «$1» (сессия осталась бы работать)"; return 0; }
      _srvdo_ssh "tmux detach-client -s $(_srvdo_q "$1")" \
        && { _srvdo_ok "от «$1» отцеплены все клиенты; сессия работает"; _srvdo_cmd "srvdo -t $1   # вернуться"; } ;;

    keys)
      _srvdo_require_tmux || return 1
      _srvdo_say "добавляю удобные клавиши в ~/.tmux.conf на сервере"
      [ "$_SRVDO_DRY" = 1 ] && { _srvdo_say "(репетиция, файл не менялся)"; return 0; }
      _srvdo_ssh 'f=$HOME/.tmux.conf
        if [ -f "$f" ] && grep -q "srvdo keys" "$f"; then
          cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
          sed -i "/# >>> srvdo keys/,/# <<< srvdo keys/d" "$f"
          echo "прежний блок srvdo заменён (бэкап рядом)"
        fi
        cat >> "$f" <<TMUXEOF
# >>> srvdo keys
bind -n F12 detach-client
bind -n M-d detach-client
set -g mouse on
set -g history-limit 50000
set -sg escape-time 10
# <<< srvdo keys
TMUXEOF
        echo "готово"' \
        && { _srvdo_ok "F12 или Alt-d выходят из сессии, не закрывая её"
             _srvdo_cmd "srvdo 'tmux source ~/.tmux.conf'   # применить к уже открытым" ; } ;;

    kill)
      _srvdo_require_tmux || return 1
      if [ "${1-}" = --all ]; then
        local live; live=$(_srvdo_names)
        [ -n "$live" ] || { _srvdo_say "сессий нет — удалять нечего"; return 1; }
        _srvdo_say "будут удалены: $(echo "$live" | paste -sd', ')"
        [ "$_SRVDO_DRY" = 1 ] && return 0
        _srvdo_confirm "уверены?" || return 1
        _srvdo_ssh 'tmux kill-server' && _srvdo_ok "все сессии удалены"
        return
      fi
      _srvdo_need "${1-}" || return 1
      [ "$_SRVDO_DRY" = 1 ] && { _srvdo_say "удалил бы «$1»"; return 0; }
      _srvdo_ssh "tmux kill-session -t=$(_srvdo_q "$1")" && _srvdo_ok "сессия «$1» удалена" ;;

    rename)
      local o=${1-} n=${2-}
      _srvdo_need "$o" || return 1
      _srvdo_valid_name "$n" || return 1
      _srvdo_have "$n" && { _srvdo_err "сессия «$n» уже существует"; return 1; }
      _srvdo_ssh "tmux rename-session -t=$(_srvdo_q "$o") $(_srvdo_q "$n")" && _srvdo_ok "$o → $n" ;;

    push)
      local s=${1-} d=${2:-$SRVDO_DIR}
      [ -n "$s" ] || { _srvdo_err "что копируем?"; _srvdo_cmd "srvdo push ~/proj"; return 2; }
      [ -e "$s" ] || { _srvdo_err "локального пути «$s» не существует"; return 1; }
      case $s in */) _srvdo_say "(слэш на конце: уедет содержимое папки, не сама папка)" ;; esac
      [ "$_SRVDO_DRY" = 1 ] && _srvdo_say "(репетиция, ничего не меняется)"
      _srvdo_rsync -avz --progress -- "$s" "$host:$d"
      local rc=$?
      [ $rc -eq 23 ] && _srvdo_warn "часть файлов не передалась — обычно нет прав на «$d»"
      [ $rc -eq 12 ] && { _srvdo_err "на сервере нет rsync"; _srvdo_cmd "srvdo apt-get install -y rsync"; }
      return $rc ;;

    pull)
      local s=${1-} d=${2:-.}
      [ -n "$s" ] || { _srvdo_err "что копируем?"; _srvdo_cmd "srvdo pull /root/results.csv"; return 2; }
      rsync -avz --progress $([ "$_SRVDO_DRY" = 1 ] && echo -n) -- "$host:$s" "$d"
      local rc=$?
      [ $rc -eq 23 ] && _srvdo_warn "путь «$s» на сервере не найден или нет прав"
      return $rc ;;

    diff)
      local s=${1-} d=${2:-$SRVDO_DIR}
      [ -n "$s" ] || { _srvdo_err "что сравниваем?"; _srvdo_cmd "srvdo diff ~/proj"; return 2; }
      [ -e "$s" ] || { _srvdo_err "локального пути «$s» не существует"; return 1; }
      _srvdo_say "('<' уедет на сервер, '*deleting' будет удалено там; ничего не меняется)"
      local -a e; mapfile -t e < <(_srvdo_excl)
      rsync "${e[@]}" -avzn --itemize-changes --delete -- "$s" "$host:$d" ;;

    watch)
      local s=${1-} d=${2:-$SRVDO_DIR}
      [ -n "$s" ] || { _srvdo_err "что синхронизируем?"; _srvdo_cmd "srvdo watch ~/proj"; return 2; }
      [ -e "$s" ] || { _srvdo_err "локального пути «$s» не существует"; return 1; }
      command -v inotifywait >/dev/null || {
        _srvdo_err "нужен inotifywait"; _srvdo_cmd "sudo apt install inotify-tools"; return 1; }
      _srvdo_say "синхронизация $s → $host:$d   (--delete включён; Ctrl-C для выхода)"
      _srvdo_rsync -az --delete -- "$s" "$host:$d" || return $?
      while inotifywait -rq -e modify,create,delete,move \
              --exclude '(\.git/|node_modules/|__pycache__/|\.swp$|~$)' "$s" >/dev/null; do
        sleep "$SRVDO_DEBOUNCE"
        if _srvdo_rsync -az --delete -- "$s" "$host:$d"; then _srvdo_say "$(date +%H:%M:%S) ✓"
        else _srvdo_warn "$(date +%H:%M:%S) rsync вернул ошибку — продолжаю следить"; fi
      done ;;

    edit)
      local f=${1-}
      [ -n "$f" ] || { _srvdo_err "какой файл?"; _srvdo_cmd "srvdo edit /etc/nginx/nginx.conf"; return 2; }
      local ed; ed=$(_srvdo_editor) || return 1
      local tmp; tmp=$(mktemp "/tmp/srvdo-$(basename "$f").XXXX")
      if ! rsync -az -- "$host:$f" "$tmp"; then
        _srvdo_err "не удалось скачать «$f» — проверьте путь и права"; rm -f "$tmp"; return 1; fi
      local before; before=$(md5sum <"$tmp")
      _srvdo_run_editor "$ed" "$tmp"
      if [ "$(md5sum <"$tmp")" = "$before" ]; then _srvdo_say "изменений нет, ничего не отправляю"; rm -f "$tmp"; return 0; fi
      if [ "$_SRVDO_DRY" = 1 ]; then _srvdo_say "отправил бы правку в $host:$f"; diff <(ssh "$host" "cat $(_srvdo_q "$f")") "$tmp"; rm -f "$tmp"; return 0; fi
      if rsync -az --backup --suffix=".srvdo-bak" -- "$tmp" "$host:$f"; then
        _srvdo_ok "отправлено (на сервере остался $f.srvdo-bak)"
      else _srvdo_err "отправить не удалось; правка сохранена в $tmp"; return 1; fi
      rm -f "$tmp" ;;

    bak)
      local p=${1:-$SRVDO_DIR}
      local out="$(basename "$p")-$(date +%F-%H%M).tar.gz"
      _srvdo_say "снимаю $host:$p → ./$out"
      if ssh "$host" "tar czf - -C $(_srvdo_q "$(dirname "$p")") $(_srvdo_q "$(basename "$p")")" >"$out"; then
        _srvdo_ok "$out ($(du -h "$out" | cut -f1))"
      else _srvdo_err "tar не справился — проверьте путь «$p» и права"; rm -f "$out"; return 1; fi ;;

    ports)
      _srvdo_say "порты, которые слушает $host:"
      _srvdo_ssh 'ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "нет ни ss, ни netstat"'
      _srvdo_cmd "srvdo tunnel ПОРТ" ;;

    tunnel)
      local spec=${1-} lp rp
      if [ -z "$spec" ]; then
        if command -v fzf >/dev/null; then
          spec=$(ssh "$host" 'ss -tlnH 2>/dev/null' \
            | awk '{split($4,a,":"); if(a[length(a)] ~ /^[0-9]+$/) print a[length(a)]}' \
            | sort -un | fzf --height 40% --reverse --prompt 'порт на сервере> ')
        fi
        [ -n "$spec" ] || { _srvdo_err "укажите порт"; _srvdo_cmd "srvdo tunnel 8080   ·   srvdo tunnel 3000:8080"; return 2; }
      fi
      case $spec in *:*) lp=${spec%%:*}; rp=${spec##*:} ;; *) lp=$spec; rp=$spec ;; esac
      case $lp$rp in *[!0-9]*) _srvdo_err "порты должны быть числами, получено «$spec»"; return 2 ;; esac
      if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$lp" 2>/dev/null; then
        _srvdo_err "локальный порт $lp занят"; _srvdo_cmd "srvdo tunnel ДРУГОЙ:$rp"; return 1; fi
      _srvdo_say "localhost:$lp → $host:$rp   (Ctrl-C чтобы закрыть)"
      ssh -N -L "$lp:localhost:$rp" "$host" ;;

    mount)
      command -v sshfs >/dev/null || { _srvdo_err "нужен sshfs"; _srvdo_cmd "sudo apt install sshfs"; return 1; }
      local mp=${1:-$SRVDO_MOUNT_BASE/$host}
      mountpoint -q "$mp" 2>/dev/null && { _srvdo_say "уже смонтировано: $mp"; return 0; }
      mkdir -p "$mp"
      sshfs "$host:$SRVDO_DIR" "$mp" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks \
        && { _srvdo_ok "$host:$SRVDO_DIR → $mp"; _srvdo_cmd "srvdo umount"; } ;;

    umount)
      local mp=${1:-$SRVDO_MOUNT_BASE/$host}
      if fusermount -u "$mp" 2>/dev/null; then _srvdo_ok "отмонтировано: $mp"
      else _srvdo_err "«$mp» не смонтирован или занят (закройте программы внутри)"; return 1; fi ;;

    info) _srvdo_ssh 'echo "── $(hostname) ──"; uptime; echo; df -h /; echo; free -h | head -2; echo;
                      tmux ls 2>/dev/null || echo "tmux: сессий нет"' ;;

    follow)
      local p=${1-}
      [ -n "$p" ] || { _srvdo_err "укажите файл"; _srvdo_cmd "srvdo -f /var/log/syslog"; return 2; }
      _srvdo_ssh --tty "[ -f $(_srvdo_q "$p") ] && tail -f -- $(_srvdo_q "$p") || { echo \"файла $p на сервере нет\" >&2; exit 1; }" ;;

    doctor)
      printf '%s── локально ──%s\n' "$_CB" "$_C0"
      local c
      for c in ssh rsync fzf inotifywait sshfs notify-send column sshpass; do
        printf '  %s %s\n' "$(_srvdo_pad "$c" 13)" "$(command -v "$c" >/dev/null && printf '%s✓%s' "$_CG" "$_C0" || printf '%s— нет%s' "$_CY" "$_C0")"
      done
      printf '  %s %s\n' "$(_srvdo_pad "конфиг" 13)" "$([ -f "$SRVDO_CONFIG" ] && echo "✓ $SRVDO_CONFIG" || echo '— нет → srvdo init')"
      printf '  %s %s\n' "$(_srvdo_pad "Host $host" 13)" "$(_srvdo_ssh_config_has "$host" && echo ✓ || echo '— нет в ~/.ssh/config → srvdo init')"
      printf '  %s %s\n' "$(_srvdo_pad "ключ" 13)" "$([ -f "$SRVDO_KEY" ] && echo "✓ $SRVDO_KEY" || echo '— нет → srvdo init')"
      printf '  %s %s\n' "$(_srvdo_pad "редактор" 13)" "${SRVDO_EDITOR:-${VISUAL:-${EDITOR:-— не задан, будет спрошен}}}"
      printf '  %s %s\n' "$(_srvdo_pad "мультиплекс" 13)" "$(grep -qi ControlMaster "$HOME/.ssh/config" 2>/dev/null && echo ✓ || echo '— добавьте ControlMaster auto, иначе Tab тормозит')"
      printf '%s── на сервере ──%s\n' "$_CB" "$_C0"
      ssh -o ConnectTimeout="$SRVDO_CONNECT_TIMEOUT" "$host" '
        for c in tmux rsync git; do
          printf "  %-13s %s\n" "$c" "$(command -v $c >/dev/null && echo ✓ || echo "— нет")"
        done
      ' || { _srvdo_err "подключиться не удалось"; _srvdo_diag; } ;;

    "") _srvdo_ssh --tty ;;
    -*) _srvdo_err "неизвестная опция «$cmd»"
        _srvdo_cmd "srvdo -h        # справка"
        _srvdo_cmd "srvdo examples  # сценарии"; return 2 ;;
    *)  _srvdo_ssh "$cmd" "$@" ;;
  esac
}

# для «srvdo help КОМАНДА» — привести название к каноническому виду
srvdo_canon() {
  case $1 in
    -t|--tmux|--session|session) echo session ;; -d|--detach|run) echo run ;;
    -a|--attach|attach) echo attach ;;  -p|--peek|peek) echo peek ;;
    -s|--send|send) echo send ;;        -w|--wait|wait) echo wait ;;
    -L|--record|record) echo record ;;  -k|--kill|kill) echo kill ;;
    -r|--rename|rename) echo rename ;;  -i|--info|info) echo info ;;
    -D|--detach-client|detach) echo detach ;;
    -f|--follow|follow) echo follow ;;  -l|--list|list) echo list ;;
    *) echo "$1" ;;
  esac
}

# ── автодополнение ────────────────────────────────────────────────────────
# Имена сессий: только осмысленные строки без пробелов, иначе compgen -W
# разобьёт мусор по словам и предложит ерунду.
_srvdo_names() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 "${1:-$SRVDO_HOST}" \
      'tmux ls -F "#{session_name}" 2>/dev/null' 2>/dev/null \
    | grep -E '^[A-Za-z0-9_.:-]+$'
}

_srvdo_cached() {
  local cache=${TMPDIR:-/tmp}/.srvdo-$SRVDO_HOST-$UID out
  if [ ! -f "$cache" ] || [ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt "$SRVDO_CACHE_TTL" ]; then
    # кэш перезаписываем только при успешном ответе сервера
    if out=$(_srvdo_names); then printf '%s\n' "$out" >"$cache"; fi
  fi
  grep -E '^[A-Za-z0-9_.:-]+$' "$cache" 2>/dev/null
}

srvdo_cache_clear() { rm -f "${TMPDIR:-/tmp}"/.srvdo-*-"$UID" "${TMPDIR:-/tmp}"/.srvdo-cmds-*; }

# Исполняемые файлы на сервере — для позиции «команда внутри сессии».
# Список большой и меняется редко, поэтому кэш на час.
_srvdo_remote_cmds() {
  local cache=${TMPDIR:-/tmp}/.srvdo-cmds-$SRVDO_HOST-$UID out
  if [ ! -f "$cache" ] || [ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt 3600 ]; then
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$SRVDO_HOST" \
            "bash -lc 'compgen -c'" 2>/dev/null \
          | grep -E '^[A-Za-z0-9_.+-]+$' | sort -u) || return 1
    [ -n "$out" ] && printf '%s\n' "$out" >"$cache"
  fi
  cat "$cache" 2>/dev/null
}

# Пути на сервере. Префикс передаётся через stdin, а не подставляется в текст
# команды: иначе кавычки и пробелы в именах ломают раскрытие, а подобранный
# префикс может вырваться из кавычек. Скрипт ниже — константа, POSIX-совместим.
_srvdo_remote_paths() {
  printf '%s\n' "$1" | ssh -o BatchMode=yes -o ConnectTimeout=3 "$SRVDO_HOST" \
    'IFS= read -r p; for f in "$p"*; do [ -e "$f" ] || continue;
       if [ -d "$f" ]; then printf "%s/\n" "$f"; else printf "%s\n" "$f"; fi; done' 2>/dev/null
}

# Варианты-пути приходят по строкам: пробелы внутри имени сохраняем,
# для readline экранируем их обратными слэшами.
_srvdo_reply_paths() {
  local cur=${1//\\ / } line
  COMPREPLY=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in "$cur"*) COMPREPLY+=("${line// /\\ }") ;; esac
  done
}

# если среди вариантов есть каталог, не дописываем пробел после слэша
_srvdo_nospace_if_dir() {
  local w
  for w in "${COMPREPLY[@]}"; do
    case $w in */) compopt -o nospace 2>/dev/null; return ;; esac
  done
}

_srvdo_aliases() {
  awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Host[[:space:]]/ {
         for(i=2;i<=NF;i++) if($i !~ /[*?]/) print $i }' "$HOME/.ssh/config" 2>/dev/null | sort -u
}

_srvdo_reply() {  # заполнить COMPREPLY из списка, разделённого переводами строк
  local cur=$1; shift
  local -a words=()
  mapfile -t words < <(printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$')
  COMPREPLY=()
  local w
  for w in "${words[@]}"; do
    case $w in "$cur"*) COMPREPLY+=("$w") ;; esac
  done
}

# bash режет слово по символам COMP_WORDBREAKS (=, :, и т.п.), поэтому
# «--alias=prod» приходит как три слова. Собираем слова сами из COMP_LINE,
# деля только по незащищённым пробелам.
_srvdo_split() {
  local line=${COMP_LINE:0:COMP_POINT} w= i=0 c prev=
  _W=()
  while [ "$i" -lt ${#line} ]; do
    c=${line:i:1}
    if [ "$c" = " " ] || [ "$c" = "	" ]; then
      if [ "$prev" = "\\" ]; then w+=$c
      elif [ -n "$w" ]; then _W+=("$w"); w=
      fi
    else
      w+=$c
    fi
    prev=$c; i=$((i+1))
  done
  _W+=("$w")          # последнее слово, возможно пустое
}

# readline вставляет вариант ПОСЛЕ последнего символа-разделителя из
# COMP_WORDBREAKS (это «=», «:», «@» и прочие), а не заменяет его. Поэтому из
# полных вариантов убираем всё до этого разделителя включительно — иначе
# «--alias=» + «--alias=prod» дало бы «--alias==prod».
_srvdo_trim() {
  local cur=$1 i c prevc strip= k breaks
  breaks=$COMP_WORDBREAKS
  [ -n "$breaks" ] || breaks='><=;|&(:'
  breaks=${breaks//[[:space:]]/}
  for (( i=${#cur}-1; i>=0; i-- )); do
    c=${cur:i:1}
    if [ "$i" -gt 0 ]; then prevc=${cur:i-1:1}; else prevc=; fi
    [ "$prevc" = "\\" ] && continue          # экранированный символ разделителем не считается
    case $breaks in *"$c"*) strip=${cur:0:i+1}; break ;; esac
  done
  [ -n "$strip" ] || return 0
  for k in "${!COMPREPLY[@]}"; do COMPREPLY[k]=${COMPREPLY[k]#"$strip"}; done
}

_srvdo_complete() {
  local -a _W
  _srvdo_split
  local n=$((${#_W[@]}-1)) cur=${_W[${#_W[@]}-1]}

  local cmds="init ping doctor config hosts use examples help cache-clear
              session list run peek attach send wait record logs detach keys kill rename
              push pull diff watch edit bak mount umount
              ports tunnel info follow"
  local opts="--alias= --host= --dir= --editor= --peek= --timeout= --exclude=
              --config= --no-reconnect --dry-run --yes --quiet --no-color --help --version"
  local editors="nvim vim nano micro helix emacs code codium subl"

  # значение опции, записанной через «=»
  case $cur in
    --alias=*|--host=*|--server=*)
      _srvdo_reply "${cur#*=}" "$(_srvdo_aliases)"
      COMPREPLY=("${COMPREPLY[@]/#/${cur%%=*}=}"); _srvdo_trim "$cur"; return ;;
    --editor=*)
      _srvdo_reply "${cur#*=}" "$editors"
      COMPREPLY=("${COMPREPLY[@]/#/--editor=}"); _srvdo_trim "$cur"; return ;;
    --dir=*|--peek=*|--timeout=*|--exclude=*|--config=*) COMPREPLY=(); return ;;
  esac

  # значение опции, записанной через пробел
  local prevw=${_W[n-1]-}
  case $prevw in
    --alias|--host|--server) _srvdo_reply "$cur" "$(_srvdo_aliases)"; _srvdo_trim "$cur"; return ;;
    --editor)                _srvdo_reply "$cur" "$editors"; _srvdo_trim "$cur"; return ;;
    --dir|--peek|--timeout|--exclude|--config) COMPREPLY=(); return ;;
  esac

  # где стоит команда: пропускаем общие опции и их значения
  local i=1 w cmdidx=0 cmd=
  while [ "$i" -lt "$n" ]; do
    w=${_W[i]}
    case $w in
      --alias|--host|--server|--dir|--editor|--peek|--timeout|--exclude|--config) i=$((i+2)) ;;
      -n|-y|-q|--*) i=$((i+1)) ;;
      *) cmdidx=$i; cmd=$w; break ;;
    esac
  done

  if [ "$cmdidx" -eq 0 ]; then
    case $cur in
      -*) _srvdo_reply "$cur" "$opts"
          # после «--opt=» пробел не нужен
          case "${COMPREPLY[*]}" in *=*) compopt -o nospace 2>/dev/null ;; esac ;;
      *)  _srvdo_reply "$cur" "$cmds"
          [ ${#COMPREPLY[@]} -eq 0 ] && [ -n "$cur" ] && \
            _srvdo_reply "$cur" "$(_srvdo_remote_cmds)" ;;
    esac
    _srvdo_trim "$cur"; return
  fi

  local pos=$((n - cmdidx))            # 1 — первый аргумент команды
  local canon; canon=$(srvdo_canon "$cmd")
  case $canon in
    session|run)
      case $pos in
        1) _srvdo_reply "$cur" "$(_srvdo_cached)" \
             "$([ "$canon" = session ] && echo '--list --last')" ;;
        2) _srvdo_reply "$cur" "$(_srvdo_remote_cmds)" ;;
        *) _srvdo_reply_paths "$cur" < <(_srvdo_remote_paths "$cur"); _srvdo_nospace_if_dir ;;
      esac ;;
    kill|detach)
      [ "$pos" -eq 1 ] && _srvdo_reply "$cur" "$(_srvdo_cached)" "--all" || COMPREPLY=() ;;
    peek|attach|send|wait|record|logs|rename)
      [ "$pos" -eq 1 ] && _srvdo_reply "$cur" "$(_srvdo_cached)" || COMPREPLY=() ;;
    use)
      case $pos in
        1) _srvdo_reply "$cur" "$(_srvdo_aliases)" ;;
        2) _srvdo_reply "$cur" "--save" ;;
        *) COMPREPLY=() ;;
      esac ;;
    ping)   [ "$pos" -eq 1 ] && _srvdo_reply "$cur" "$(_srvdo_aliases)" || COMPREPLY=() ;;
    config) [ "$pos" -eq 1 ] && _srvdo_reply "$cur" "edit" || COMPREPLY=() ;;
    help)   [ "$pos" -eq 1 ] && _srvdo_reply "$cur" "$cmds" || COMPREPLY=() ;;
    push|diff|watch)
      case $pos in
        1) COMPREPLY=($(compgen -f -- "$cur")) ;;
        2) _srvdo_reply_paths "$cur" < <(_srvdo_remote_paths "$cur"); _srvdo_nospace_if_dir ;;
        *) COMPREPLY=() ;;
      esac ;;
    pull|edit|bak|follow)
      case $pos in
        1) _srvdo_reply_paths "$cur" < <(_srvdo_remote_paths "$cur"); _srvdo_nospace_if_dir ;;
        2) [ "$canon" = pull ] && COMPREPLY=($(compgen -d -- "$cur")) || COMPREPLY=() ;;
        *) COMPREPLY=() ;;
      esac ;;
    mount|umount)
      [ "$pos" -eq 1 ] && COMPREPLY=($(compgen -d -- "$cur")) || COMPREPLY=() ;;
    *)
      _srvdo_reply_paths "$cur" < <(_srvdo_remote_paths "$cur"); _srvdo_nospace_if_dir ;;
  esac
  _srvdo_trim "$cur"
}
complete -F _srvdo_complete srvdo
