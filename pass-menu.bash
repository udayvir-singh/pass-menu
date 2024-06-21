#!/usr/bin/env bash

IFS=$'\n'

set +B -feuo pipefail
shopt -s lastpipe

# ---------------------- #
#       ENVIRONMENT      #
# ---------------------- #
readonly PASSWORD_STORE_DIR="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
readonly PASSWORD_STORE_CLIP_TIME="${PASSWORD_STORE_CLIP_TIME:-45}"
readonly PASSWORD_STORE_X_SELECTION="${PASSWORD_STORE_X_SELECTION:-clipboard}"


# ---------------------- #
#         GLOBALS        #
# ---------------------- #
FILE_NAME=""
KEY_NAME=""
FILE=()
DATA=()

BUFFER=""
CURSOR=0
LINE=0

MENU_CMD=()
PROMPT_FLAG=""
FILE_PROMPT="file"
KEY_PROMPT="key"
MODE_PROMPT="mode"
LOG_TYPE="compact"
PASS_MODE="ask"


# ---------------------- #
#          REGEX         #
# ---------------------- #
readonly ID_REGEX='([-_[:alnum:]]|[-_[:alnum:]][-_[:alnum:][:blank:]]*[-_[:alnum:]])'
readonly INDEX_REGEX='\[[1-9][0-9]*\]'

is_otpauth () [[ "${1}" =~ ^otpauth:// ]]

is_action () [[ "${1}" =~ ^action\( ]]

is_field () [[ "${1}" =~ ^[[:blank:]]*${ID_REGEX}[[:blank:]]*: ]]

is_identifier () [[ "${1}" =~ ^${ID_REGEX}$ ]]

is_numbered_key () [[
    "${1}" =~ ^(${ID_REGEX}|\(\(${ID_REGEX}\)\))${INDEX_REGEX}$
]]

is_field_key () [[
    ! "${1}" =~ ^OTP(${INDEX_REGEX}|\(.+\))?$ &&
    "${1}" =~ ^${ID_REGEX}(${INDEX_REGEX})?$
]]

is_otp_key () [[
    "${1}" =~ ^OTP(${INDEX_REGEX}|\(.+\))?$
]]

is_named_otp_key () [[
    "${1}" =~ ^OTP\(.+\)$
]]

is_action_key () [[
    "${1}" =~ ^\(\(${ID_REGEX}\)\)(${INDEX_REGEX})?$
]]

bool () {
    "${@}" && echo true || echo false
}


# ---------------------- #
#    EXTERNAL COMMANDS   #
# ---------------------- #
if [ -v WAYLAND_DISPLAY ]; then
    readonly DISPLAY_NAME="${WAYLAND_DISPLAY}"

    press_tab () { wtype -k tab; }

    press_enter () { wtype -k enter; }

    type_str () { wtype -; }

    clip_set () { wl-copy $([ "${PASSWORD_STORE_X_SELECTION}" = "primary" ] && printf '%s' "--primary") "${1}"; }

    clip_get () { wl-paste $([ "${PASSWORD_STORE_X_SELECTION}" = "primary" ] && printf '%s' "--primary"); }
else
    readonly DISPLAY_NAME="${DISPLAY:-none}"

    press_tab () { xdotool key --clearmodifiers Tab; }

    press_enter () { xdotool key --clearmodifiers Enter; }

    type_str () { xdotool type --clearmodifiers --file -; }

    clip_set () { printf '%s' "${1}" | xclip -selection "${PASSWORD_STORE_X_SELECTION}"; }

    clip_get () { xclip -selection "${PASSWORD_STORE_X_SELECTION}" -o; }
fi

clip () {
    local KEY_NAME="${1}"
    local STR; readstring STR
    local TIMER_NAME="password store sleep on display ${DISPLAY_NAME}"

    # message user when setting clipboard
    info "Copied ${KEY_NAME} to clipboard. Will clear in ${PASSWORD_STORE_CLIP_TIME} seconds."

    # spawn a background process
    {
        # kill previous processes
        pkill -f "^${TIMER_NAME}" 2>/dev/null && sleep 0.5

        # set clipboard and revert after timeout
        local ORIG="$(clip_get 2>/dev/null | base64)"

        clip_set "${STR}"

        ( exec -a "${TIMER_NAME}" sleep "${PASSWORD_STORE_CLIP_TIME}" ) || true

        if [ "$(clip_get 2>/dev/null)" = "${STR}" ]; then
            clip_set "$(base64 --decode <<< "${ORIG}")"

            if [ "${LOG_TYPE}" = 'notify' ]; then
                info "Cleared ${KEY_NAME} from clipboard."
            fi
        fi
    } & disown
}

gen_otp () {
    # get otpauth parameters
    declare -A PARAMS=(); readassoc PARAMS

    # generate oathtool command
    local CMD=("oathtool" "-b")

    case "${PARAMS[protocol]}" in
        totp)
            if [ -v PARAMS[algorithm] ]; then
                CMD+=(--totp="${PARAMS[algorithm]}")
            else
                CMD+=("--totp")
            fi

            [ -v PARAMS[period] ] && CMD+=("--time-step-size=${PARAMS[period]}s")
        ;;
        hotp)
            local OTP_COUNTER=$(( ${PARAMS[counter]} + 1 ))
            local OTP_IDX=$(( ${PARAMS[line]} - 1 ))

            [[ "${FILE[${OTP_IDX}]}" =~ ^(otpauth://[^?]+?.*)counter=[0-9]+(.*)$ ]] || use_error

            FILE[${OTP_IDX}]="${BASH_REMATCH[1]}counter=${OTP_COUNTER}${BASH_REMATCH[2]}"

            printf '%s\n' "${FILE[*]}" | write_pass_file "${FILE_NAME}"

            CMD+=("--hotp" "--counter=${OTP_COUNTER}")
        ;;
        *) use_error ;;
    esac

    [ -v PARAMS[digits] ] && CMD+=("--digits=${PARAMS[digits]}")

    CMD+=("${PARAMS[secret]}")

    # run oathtool
    "${CMD[@]}"
}

run_action () {
    # get commands
    local ARRAY; readarray ARRAY

    # run commands
    local LEN=${#ARRAY[@]}
    local IDX

    for (( IDX = 0; IDX < LEN; IDX += 2 )); do
        local CMD="${ARRAY[${IDX}]}"
        local ARG="${ARRAY[(( IDX + 1))]}"

        case "${CMD}" in
            :tab)    press_tab ;;
            :enter)  press_enter ;;
            :run)    get_raw_value "${ARG}" | run_action ;;
            :type)   get_value "${ARG}" | type_str ;;
            :clip)   get_value "${ARG}" | clip "${ARG}" ;;
            :logger) info "${ARG}" ;;
            :sleep)  sleep "${ARG}" ;;
            :exec)   bash -c "${ARG}" -- "${FILE_NAME}" ;;
            *)       use_error ;;
        esac
    done
}


# ---------------------- #
#          PASS          #
# ---------------------- #
is_pass_file () [[ -r "${PASSWORD_STORE_DIR}/${1}.gpg" ]]

list_pass_filenames () {
    find "${PASSWORD_STORE_DIR}" -type f -name "*.gpg" -printf '%P\n' |
        sed 's/\.gpg$//' |
        sort ||
        true
}

read_pass_file () {
    local NAME="${1}"

    pass show "${NAME}"
}

write_pass_file () {
    local NAME="${1}"

    pass insert -m "${NAME}" </dev/stdin >/dev/null
}


# ---------------------- #
#          UTILS         #
# ---------------------- #
oneof () {
    local STR="${1}"; shift

    local ARG
    for ARG in "${@}"; do
        [ "${STR}" = "${ARG}" ] && return 0
    done

    return 1
}

repeat () {
    local STR="${1}"
    local INT="${2}"

    if (( INT > 0 )); then
        printf "%0.s${STR}" $(seq "${INT}")
    fi
}

quote () {
    local STR="${1}"

    STR="${STR//\"/\\\"}"
    STR="${STR//$'\n'/\\n}"

    printf '"%s"' "${STR}"
}

shell_quote () {
    local STR="${1}"

    STR="${STR//\'/\'\\\'\'}"
    STR="${STR//$'\n'/\'$\'\\n\'\'}"

    printf "'%s'" "${STR}"
}

trim_start () {
    local STR="${1}"

    [[ "${STR}" =~ ^[[:blank:]]* ]]

    printf '%s' "${STR:${#BASH_REMATCH[0]}}"
}

trim_end () {
    local STR="${1}"

    [[ "${STR}" =~ [[:blank:]]*$ ]]

    printf '%s' "${STR:0:(( ${#STR} - ${#BASH_REMATCH[0]} ))}"
}

trim () {
    local STR="${1}"

    trim_start "$(trim_end "${STR}")"
}

url_decode () {
    local STR="${1}"

    STR="${STR//+/ }"
    STR="${STR//%/\\x}"

    printf '%b' "${STR}"
}

getattr () {
    local VAR="${1}"

    set +u
    eval printf '%s' '"${'"${VAR}"'@a}"'
    set -u
}

readstring () {
    local VAR="${1}"

    read -r -d '' "${VAR}" || true
}

readarray () {
    local VAR="${1}"

    mapfile -t "${VAR}"
}

readassoc () {
    local VAR="${1}"
    local ARR; readarray ARR
    local LEN=${#ARR[@]}

    if [ ! "$(getattr "${VAR}")" = 'A' ]; then
        unset "${VAR}"
        declare -gA "${VAR}=()"
    fi

    local IDX
    for (( IDX = 0; IDX < LEN; IDX += 2 )); do
        local KEY="${ARR[${IDX}]}"
        local VAL="${ARR[(( IDX + 1 ))]?Missing value after key}"

        eval "${VAR}['${KEY}']"='${VAL}'
    done
}


# ---------------------- #
#         LOGGING        #
# ---------------------- #
eprintf () {
    printf "${@}" >&2
}

format_lineno () {
    local CURSOR=1
    local LENGTH="$(( ${#BASH_LINENO[@]} - 2))"
    local LINENO

    for LINENO in "${BASH_LINENO[@]:${CURSOR}:${LENGTH}}"; do
        printf '%s' "${LINENO}"

        (( CURSOR++ < LENGTH )) && printf ", "
    done
}

info () {
    local MSG="${1}"

    case "${LOG_TYPE}" in
        compact)
            eprintf 'pass-menu: %s: %s\n' "${FILE_NAME}" "${MSG}"
        ;;
        human)
            eprintf 'Info: %s: %s\n' "${FILE_NAME}" "${MSG}"
        ;;
        notify)
            notify-send "Pass Menu (${FILE_NAME})" "${MSG}"
        ;;
        *)
            eprintf 'pass-menu: Internal error: Invalid LOG_TYPE while calling %s' "${FUNCNAME}"
        ;;
    esac
}

arg_error () {
    local MSG="${1}"
    local ARG="$(quote "${2}")"

    case "${LOG_TYPE}" in
        compact)
            eprintf 'pass-menu: Argument error: %s: %s\n' "${MSG}" "${ARG}"
        ;;
        human)
            eprintf 'Error while parsing argument:\n'
            eprintf '└─ %s: %s\n' "${MSG}"  "${ARG}"
        ;;
        notify)
            notify-send "Pass Menu (Argument Error)" "While parsing ${ARG}:\n${MSG}"
        ;;
        *)
            eprintf 'pass-menu: Internal error: Invalid LOG_TYPE while calling %s' "${FUNCNAME}"
        ;;
    esac

    exit 1
}

read_error () {
    local NAME="${1}"
    local MSG="${2}"

    case "${LOG_TYPE}" in
        compact)
            eprintf 'pass-menu: Error while reading %s: %s\n' "${NAME}" "${MSG}"
        ;;
        human)
            eprintf 'Error while reading %s:\n' "${NAME}"
            eprintf '└─ %s\n' "${MSG}"
        ;;
        notify)
            notify-send "Pass Menu (Error)" "While reading ${NAME}:\n${MSG}"
        ;;
        *)
            eprintf 'pass-menu: Internal error: Invalid LOG_TYPE while calling %s' "${FUNCNAME}"
        ;;
    esac

    exit 1
}

syntax_error () {
    local MSG="${1}"
    local DESC="${2}"
    local ERR_OFFSET="${3}"
    local ERR_LENGTH="${4}"

    case "${LOG_TYPE}" in
        compact)
            eprintf 'pass-menu: Syntax error: %s:%d:%d: %s\n' "${FILE_NAME}" "${LINE}" "${ERR_OFFSET}" "${MSG}"
        ;;
        human)
            eprintf 'Syntax error in %s at line %d, column %d:\n' "${FILE_NAME}" "${LINE}" "${ERR_OFFSET}"
            eprintf '└─ %s\n\n' "${MSG}"
            eprintf '%s\n' "${BUFFER}"
            repeat ' ' "${ERR_OFFSET}"
            repeat '^' "${ERR_LENGTH}"
            eprintf '\n'

            if [ -n "${DESC}" ]; then
                eprintf '\n%s\n' "${DESC}"
            fi
        ;;
        notify)
            notify-send "Pass Menu (Syntax Error)" \
                        "In ${FILE_NAME}:\nAt line ${LINE}, column ${ERR_OFFSET}:\n${MSG}"
        ;;
        *)
            eprintf 'pass-menu: Internal error: Invalid LOG_TYPE while calling %s' "${FUNCNAME}"
        ;;
    esac

    exit 1
}

internal_error () {
    local MSG="${1}"
    local LINE_INFO="[${2:-$(format_lineno)}]"

    case "${LOG_TYPE}" in
        compact)
            eprintf 'pass-menu: Internal error:%s: %s\n' "${LINE_INFO}" "${MSG}"
        ;;
        human)
            eprintf 'Internal error in %s at lines %s:\n' "$(basename -- "${0}")" "${LINE_INFO}"
            eprintf '└─ %s\n' "${MSG}"
        ;;
        notify)
            notify-send "Pass Menu (Internal error)" "At lines ${LINE_INFO}:\n${MSG}"
        ;;
        *)
            eprintf 'pass-menu: Internal error: Invalid LOG_TYPE while calling %s' "${FUNCNAME}"
        ;;
    esac

    exit 1
}

use_error () {
    internal_error "Invalid use of ${FUNCNAME[@]:1:1} function" "$(format_lineno)"
}


# ---------------------- #
#         PARSER         #
# ---------------------- #
has_buffer () (( CURSOR < ${#BUFFER} ))

set_buffer () {
    BUFFER="${1}"
    CURSOR=0
    LINE=$(( LINE + 1 ))
}

inc_cursor () {
    CURSOR=$(( CURSOR + ${1:-1} ))
}

get_char () {
    printf '%s' "${BUFFER:${CURSOR}:1}"
}

collect_till () {
    local CHARS="${1}"
    local VAR="${2}"

    [[ "${BUFFER:${CURSOR}}" =~ ^[^${CHARS}]* ]]

    CURSOR=$(( CURSOR + ${#BASH_REMATCH[0]} ))

    printf '%s' "${BASH_REMATCH[0]}" | readstring "${VAR}"
}

consume_whitespace () {
    [[ "${BUFFER:${CURSOR}}" =~ ^[[:blank:]]* ]]

    CURSOR=$(( CURSOR + ${#BASH_REMATCH[0]} ))
}

parse_string () {
    local VAR="${1}"

    # safety check
    [ "$(get_char)" = '"' ] || use_error

    # parse string body
    local STRING_START="${CURSOR}"
    local STRING_BODY=""

    inc_cursor
    while has_buffer; do
        local CHUNK
        collect_till '"\$' CHUNK

        # push non-empty chunk into string buffer
        if [ -n "${CHUNK}" ]; then
            STRING_BODY+="${CHUNK}"
            continue
        fi

        # peek next char
        local CHAR_START="${CURSOR}"
        local CHAR="$(get_char)"

        # handle escape sequence
        if [ "${CHAR}" = '\' ]; then
            # get sequence char
            inc_cursor
            CHAR="$(get_char)"; inc_cursor

            # validate sequence char
            if ! oneof "${CHAR}" '"' '$' '\'; then
                syntax_error "Invalid escape sequence: \\${CHAR}" "" "${CHAR_START}" 2
            fi

            # push escaped char
            STRING_BODY+="${CHAR}"
            continue
        fi

        # handle identifier
        if [ "${CHAR}" = '$' ]; then
            inc_cursor

            # handle singular dollar sign
            if [ "$(get_char)" != '{' ]; then
                STRING_BODY+='$'
                continue
            fi

            inc_cursor

            # collect identifier name
            local ID_START="${CURSOR}"
            local ID_NAME
            collect_till '}' ID_NAME

            # check for closing brace
            if [ "$(get_char)" != '}' ]; then
                syntax_error "Missing closing brace for identifier" "" \
                             "${CHAR_START}" 2
            fi

            inc_cursor

            # validate identifier
            if [[ "${ID_NAME}" =~ ^[[:blank:]]*$ ]]; then
                syntax_error "Missing identifier name inside braces" "" \
                             "${CHAR_START}" $(( ${#ID_NAME} + 3 ))
            fi

            if ! is_field_key "${ID_NAME}"; then
                syntax_error "Invalid identifier name inside braces: $(quote "${ID_NAME}")" "" \
                             "${ID_START}" ${#ID_NAME}
            fi

            if ! has_value "${ID_NAME}"; then
                syntax_error "No value found for identifier: $(quote "${ID_NAME}")" "" \
                             "${CHAR_START}" $(( ${#ID_NAME} + 3 ))
            fi

            # push value
            STRING_BODY+="$(get_raw_value "${ID_NAME}")"
            continue
        fi

        break
    done

    # check for closing quote
    if [ "$(get_char)" != '"' ]; then
        syntax_error "Missing closing quote for string" "" \
                     "${STRING_START}" 1
    fi

    inc_cursor

    # validate string
    if [ -z "${STRING_BODY}" ]; then
        syntax_error "Empty string is not allowed" "" \
                     "${STRING_START}" 2
    fi

    printf '%s' "${STRING_BODY}" | readstring "${VAR}"
}

parse_field () {
    # safety check
    is_field "${BUFFER}" || use_error

    # parse key
    local RAW_KEY
    collect_till ':' RAW_KEY

    local KEY="$(trim "${RAW_KEY}")"

    # validate key
    if [ "${KEY}" = OTP ]; then
        syntax_error "Field key cannot have a reserved name: OTP" "" \
                     0 ${#RAW_KEY}
    fi

    # skip colon
    inc_cursor

    # skip whitespace
    consume_whitespace

    # parse value
    local VALUE

    if [ "$(get_char)" = '"' ]; then
        parse_string VALUE
    else
        VALUE="$(trim_end "${BUFFER:${CURSOR}}")"

        if [ -z "${VALUE}" ]; then
            syntax_error "Missing value after field name" "" 0 0
        fi
    fi

    # push data
    DATA+=("${KEY}" "${VALUE}")
}

parse_otpauth () {
    # safety check
    is_otpauth "${BUFFER}" || use_error

    # embed line position of URI
    declare -A PARAMS=()

    PARAMS[line]="${LINE}"

    # skip "otpauth://"
    local PROTOCOL_START=10
    inc_cursor "${PROTOCOL_START}"

    # parse protocol
    local PROTOCOL
    collect_till '/?' PROTOCOL

    # validate protocol
    if ! oneof "${PROTOCOL}" 'totp' 'hotp'; then
        syntax_error "Invalid otpauth protocol: $(quote "${PROTOCOL}")" "" \
                     "${PROTOCOL_START}" ${#PROTOCOL}
    fi

    PARAMS[protocol]="${PROTOCOL}"

    # skip protocol separator
    [ "$(get_char)" = '/' ] && inc_cursor

    # parse label
    local LABEL_START="${CURSOR}"
    local LABEL
    collect_till '?' LABEL

    if [ -n "${LABEL}" ]; then
        # decode label
        LABEL="$(url_decode "${LABEL}")"
        LABEL="${LABEL//\(/%28}"
        LABEL="${LABEL//\)/%29}"

        # check for duplicate otpauth URI
        if has_value "OTP(${LABEL})"; then
			declare -A DUP_PARAMS=()

            readassoc DUP_PARAMS <<< "$(get_raw_value "OTP(${LABEL})")"

            syntax_error "Duplicate otpauth URI with label: $(quote "${LABEL}")" \
                         "A URI with the same label already exists at line ${DUP_PARAMS[line]}" \
                         "${LABEL_START}" ${#LABEL}
        fi

        PARAMS[label]="${LABEL}"
    fi

    # check for params
    local PARAMS_START="${CURSOR}"
    local PARAMS_SEP="$(get_char)"; inc_cursor

    if [ "${PARAMS_SEP}" != '?' ] || ! has_buffer; then
        syntax_error "Missing parameters in otpauth URI" "" 0 0
    fi

    if [[ "${BUFFER:${CURSOR}}" =~ / ]]; then
        syntax_error "Invalid format of parameters in otpauth URI" "" \
                     "${PARAMS_START}" $(( ${#BUFFER} - PARAMS_START ))
    fi

    # parse otpauth parameters
    while has_buffer; do
        # parse parameter name
        local NAME_START="${CURSOR}"
        local NAME
        collect_till '=&' NAME

        # validate parameter name
        if [ -z "${NAME}" ]; then
            syntax_error "Missing parameter after separator in otpauth URI" "" \
                         $(( NAME_START - 1))  1
        fi

        if [[ -v "PARAMS[${NAME}]" ]]; then
            syntax_error "Duplicate parameter in otpauth URI: $(quote "${NAME}")" "" \
                         "${NAME_START}" ${#NAME}
        fi

        # check for equal sign
        if [ "$(get_char)" != '=' ]; then
            syntax_error "Missing equal sign after otpauth parameter: $(quote "${NAME}")" "" \
                         "${NAME_START}" ${#NAME}
        fi

        inc_cursor

        # parse argument
        local ARG_START="${CURSOR}"
        local ARG
        collect_till '&' ARG

        # validate argument
        if [ -z "${ARG}" ]; then
            syntax_error "Missing argument for otpauth parameter: $(quote "${NAME}") " "" \
                         $(( ARG_START - 1))  1
        fi


        # validate parameter
        otp_arg_error () {
            local DESC="${1}"

            syntax_error "Invalid ${NAME} in otpauth parameters: $(quote "${ARG}")" "${DESC}" \
                         "${NAME_START}" ${#NAME}
        }

        case "${PROTOCOL}/${NAME}" in
            */issuer)
                if [[ ! "${ARG}" =~ ^([@-_.~[:alnum:]]|%[[:xdigit:]][[:xdigit:]])+$ ]]; then
                    otp_arg_error "Expected issuer to be in valid URL encoding"
                fi

                ARG="$(url_decode "${ARG}")"
            ;;
            */secret)
                ARG="${ARG^^}"

                if [[ ! "${ARG}" =~ ^[A-Z0-9=]+$ ]]; then
                    otp_arg_error "Expected secret to be a valid Base32 value"
                fi
            ;;
            */digits)
                if [[ ! "${ARG}" =~ ^0*[6-8]$ ]]; then
                    otp_arg_error "Expected digits to be a number between 6 and 8"
                fi
            ;;
            totp/algorithm)
                if ! oneof "${ARG}" 'SHA1' 'SHA256' 'SHA512'; then
                    otp_arg_error "Expected algorithm to be either SHA1, SHA256 or SHA512"
                fi
            ;;
            totp/period)
                if [[ ! "${ARG}" =~ ^0*([1-9][0-9]*)$ ]]; then
                    otp_arg_error "Expected ${NAME} to be a natural number"
                fi

                ARG="${BASH_REMATCH[1]}"
            ;;
            hotp/counter)
                if [[ ! "${ARG}" =~ ^[0-9]+$ ]]; then
                    otp_arg_error "Expected ${NAME} to be a positive number"
                fi
            ;;
            *)
                syntax_error "Invalid parameter in otpauth URI: $(quote "${NAME}")" "" \
                             "${NAME_START}" ${#NAME}
            ;;
        esac

        # skip parameter separators
        [ "$(get_char)" = '&' ] && inc_cursor

        # push parameter
        PARAMS["${NAME}"]="${ARG}"
    done

    # validate required parameters
    if [ ! -v PARAMS[secret] ]; then
        syntax_error "Missing secret in otpauth parameters" "" \
                     "${PARAMS_START}" $(( ${#BUFFER} - PARAMS_START ))
    fi

    if [ "${PROTOCOL}" = 'hotp' ] && [ ! -v PARAMS[counter] ]; then
        syntax_error "Missing counter in otpauth parameters" "" \
                     "${PARAMS_START}" $(( ${#BUFFER} - PARAMS_START ))
    fi

    # convert associative params into array value
    local ARRAY=()

    local KEY
    for KEY in "${!PARAMS[@]}"; do
        ARRAY+=("${KEY}" "${PARAMS[${KEY}]}")
    done

    # push data
    DATA+=("OTP" "${ARRAY[*]}")
}

parse_action () {
    # safety check
    is_action "${BUFFER}" || use_error

    # skip "action("
    local NAME_START=7

    inc_cursor "${NAME_START}"

    # parse action name
    local NAME
    collect_till ')' NAME

    # check for closing brace
    if [ "$(get_char)" != ')' ]; then
        syntax_error "Missing closing brace for action" "" \
                     $(( NAME_START - 1 )) 1
    fi

    inc_cursor

    # validate action name
    if [[ "${NAME}" =~ ^[[:blank:]]*$ ]]; then
        syntax_error "Missing action name" "" \
                     $(( NAME_START - 1 )) $(( ${#NAME} + 2 ))
    fi

    if ! is_identifier "${NAME}"; then
        syntax_error "Invalid action name" "" \
                     "${NAME_START}" ${#NAME}
    fi

    # skip whitespace
    consume_whitespace

    # parse commands
    local ARRAY=()

    while has_buffer; do
        # check for leading whitespace
        if [[ ! "${BUFFER:(( CURSOR - 1 )):1}" =~ ^[[:blank:]]$ ]]; then
            syntax_error "Missing whitespace before command name" "" \
                         "$(( CURSOR - 1 ))" 1
        fi

        # parse command name
        local CMD_START="${CURSOR}"
        local CMD
        collect_till '[:blank:]' CMD

        # validate command name
        case "${CMD}" in
            :type | :clip | :run | :sleep | :log | :exec) ;;
            :tab | :enter)
                # skip parsing argument for tab and enter
                ARRAY+=("${CMD}" "-")
                consume_whitespace
                continue
            ;;
            *)
                syntax_error "Invalid command name: $(quote "${CMD}")" "" \
                             "${CMD_START}" ${#CMD}
            ;;
        esac

        # skip whitespace after command name
        consume_whitespace

        # check for argument
        if ! has_buffer; then
            syntax_error "Missing argument command: $(quote "${CMD}")" "" \
                         "${CMD_START}" ${#CMD}
        fi

        # parse argument
        local ARG_START="${CURSOR}"
        local ARG

        if [ "$(get_char)" = '"' ]; then
            parse_string ARG
        else
            collect_till '[:blank:]' ARG
        fi

        # expand csv values after run command
        if [ "${CMD}" = :run ]; then
            local VAL CSV="${ARG},"

            while [[ "${CSV}" =~ ^([^,]*),(.*)$ ]]; do
                VAL="${BASH_REMATCH[1]}"
                CSV="${BASH_REMATCH[2]}"

                if ! is_action_key "((${VAL}))"; then
                    syntax_error "Invalid action name after ${CMD#:} command: $(quote "${VAL}")" "" \
                                 "${ARG_START}" $(( CURSOR - ARG_START ))
                fi

                if ! has_value "((${VAL}))"; then
                    syntax_error "Unknown action name after ${CMD#:} command: $(quote "${VAL}")" "" \
                                 "${ARG_START}" $(( CURSOR - ARG_START ))
                fi

                # push run command
                ARRAY+=("${CMD}" "((${VAL}))")
            done

            # skip trailing whitespace
            consume_whitespace
            continue
        fi

        # validate argument
        case "${CMD}" in
            :type | :clip)
                if ! (is_field_key "${ARG}" || is_otp_key "${ARG}"); then
                    syntax_error "Invalid identifier name after ${CMD#:} command: $(quote "${ARG}")" "" \
                                 "${ARG_START}" $(( CURSOR - ARG_START ))
                fi

                if ! has_value "${ARG}"; then
                    syntax_error "Unknown identifier name after ${CMD#:} command: $(quote "${ARG}")" "" \
                                 "${ARG_START}" $(( CURSOR - ARG_START ))
                fi
            ;;
            :sleep)
                if ! [[ "${ARG}" =~ ^(([0-9]+\.?[0-9]*)|(\.?[0-9]+))(e[+-]?[0-9]+)?(s|m|h|d)?$ ]]; then
                    syntax_error "Invalid duration after ${CMD#:} command: $(quote "${ARG}")" "" \
                                 "${ARG_START}" $(( CURSOR - ARG_START ))
                fi
            ;;
        esac

        # push command
        ARRAY+=("${CMD}" "${ARG}")

        # skip trailing whitespace
        consume_whitespace
    done

    # check for commands
    if [ ${#ARRAY[@]} = 0 ]; then
        syntax_error "Missing commands in action body" "" 0 0
    fi

    # push data
    DATA+=("((${NAME}))" "${ARRAY[*]}")
}

parse_password () {
    # trim trailing whitespace from line
    local VALUE="$(trim_end "${BUFFER}")"

    # return if line is empty
    [ -z "${VALUE}" ] && return

    # push data
    DATA+=("Password" "${VALUE}")
}

parse_file () {
    local BUF

    for BUF in "${FILE[@]}"; do
        set_buffer "${BUF}"

        if is_otpauth "${BUFFER}"; then
            parse_otpauth
        elif is_action "${BUFFER}"; then
            parse_action
        elif is_field "${BUFFER}"; then
            parse_field
        elif [ "${LINE}" = 1 ]; then
            parse_password
        fi
    done
}


# ---------------------- #
#          DATA          #
# ---------------------- #
list_keys () {
    local LEN=${#DATA[@]}
    local TOP=()
    local BOT=()
    local IDX JDX

    for (( IDX = 0; IDX < LEN; IDX += 2 )); do
        local KEY="${DATA[$IDX]}"

        # count the sequential number of key
        local KEY_NUM=1

        for (( JDX = 0; JDX < IDX; JDX += 2 )); do
            if [ "${DATA[$JDX]}" = "${KEY}" ]; then
                KEY_NUM=$(( KEY_NUM + 1 ))
            fi
        done

        # check for duplicate keys
        local HAS_DUPLICATE=0

        if [ "${KEY_NUM}" -gt 1 ]; then
            HAS_DUPLICATE=1
        else
            for (( JDX = IDX + 2; JDX < LEN; JDX += 2 )); do
                if [ "${DATA[$JDX]}" = "${KEY}" ]; then
                    HAS_DUPLICATE=1
                    break
                fi
            done
        fi

        # print key
        if [ "${HAS_DUPLICATE}" -eq 1 ]; then
            if is_otp_key "${KEY}"; then
                declare -A PARAMS=()

                readassoc PARAMS <<< "${DATA[(( IDX + 1 ))]}"

                if [ -v PARAMS[label] ]; then
                    BOT+=("${KEY}(${PARAMS[label]})")
                else
                    BOT+=("${KEY}[${KEY_NUM}]")
                fi
            else
                if is_action_key "${KEY}"; then
                    TOP+=("${KEY}[${KEY_NUM}]")
                else
                    BOT+=("${KEY}[${KEY_NUM}]")
                fi
            fi
        else
            if is_action_key "${KEY}"; then
                TOP+=("${KEY}")
            else
                BOT+=("${KEY}")
            fi
        fi
    done

    [ ${#TOP[@]} == 0 ] || printf '%s\n' "${TOP[*]}"
    [ ${#BOT[@]} == 0 ] || printf '%s\n' "${BOT[*]}"
}

has_value () {
    local NAME="${1}"
    local LEN=${#DATA[@]}
    local IDX

    if is_numbered_key "${NAME}"; then
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            local KEY="${DATA[$IDX]}"

            # count the sequential number of key
            local KEY_NUM=1

            for (( JDX = 0; JDX < IDX; JDX += 2 )); do
                if [ "${DATA[$JDX]}" = "${KEY}" ]; then
                    KEY_NUM=$(( KEY_NUM + 1 ))
                fi
            done

            # return if name matches key
            [ "${NAME}" = "${KEY}[${KEY_NUM}]" ] && return 0
        done
    elif is_named_otp_key "${NAME}"; then
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            local KEY="${DATA[$IDX]}"

            # skip non OTP keys
            [ "${KEY}" != OTP ] && continue

            # get label of otpauth URI
            declare -A PARAMS=()

            readassoc PARAMS <<< "${DATA[(( IDX + 1 ))]}"

            # return if name matches key
            [ "${NAME}" = "${KEY}(${PARAMS[label]:-})" ] && return 0
        done
    else
        # else do raw search
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            [ "${NAME}" = "${DATA[$IDX]}" ] && return 0
        done
    fi

    return 1
}

get_raw_value () {
    local NAME="${1}"
    local LEN=${#DATA[@]}
    local IDX

    if is_numbered_key "${NAME}"; then
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            local KEY="${DATA[$IDX]}"

            # count the sequential number of key
            local KEY_NUM=1

            for (( JDX = 0; JDX < IDX; JDX += 2 )); do
                if [ "${DATA[$JDX]}" = "${KEY}" ]; then
                    KEY_NUM=$(( KEY_NUM + 1 ))
                fi
            done

            # return if name matches key
            if [ "${NAME}" = "${KEY}[${KEY_NUM}]" ]; then
                printf '%s' "${DATA[(( IDX + 1 ))]}"
                return
            fi
        done
    elif is_named_otp_key "${NAME}"; then
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            local KEY="${DATA[$IDX]}"

            # get label of otpauth URI
            declare -A PARAMS=()

            readassoc PARAMS <<< "${DATA[(( IDX + 1 ))]}"

            # return if name matches key
            if [ "${NAME}" = "${KEY}(${PARAMS[label]:-})" ]; then
                printf '%s' "${DATA[(( IDX + 1 ))]}"
                return
            fi
        done
    else
        # else do raw search
        for (( IDX = 0; IDX < LEN; IDX += 2 )); do
            if [ "${NAME}" = "${DATA[$IDX]}" ]; then
                printf '%s' "${DATA[(( IDX + 1 ))]}"
                return
            fi
        done
    fi

    use_error
}

get_value () {
    local NAME="${1}"

    if is_action_key "${NAME}"; then
        use_error
    elif is_otp_key "${NAME}"; then
        get_raw_value "${NAME}" | gen_otp
    else
        get_raw_value "${NAME}"
    fi
}

print_data () {
    # get keys
    local KEYS

    list_keys | readarray KEYS

    # calculate max key width
    local MAX_WIDTH=0
    local KEY

    for KEY in "${KEYS[@]}"; do
        [ ${#KEY} -gt "${MAX_WIDTH}" ] && MAX_WIDTH=${#KEY}
    done

    # print key-value pairs
    for KEY in "${KEYS[@]}"; do
        # get value
        local VALUE="$(get_raw_value "${KEY}")"

        # escape newlines
        VALUE="${VALUE//$'\n'/] [}"

        # print value
        printf "%-${MAX_WIDTH}s = [%s]\n" "${KEY}" "${VALUE}"
    done
}


# ---------------------- #
#          HELP          #
# ---------------------- #
print_help () {
    cat << EOF
Usage: pass-menu [OPTIONS] -- COMMAND [ARGUMENTS]

Options:
  -t, --type                  Type the output
  -c, --clip                  Copy the output to the clipboard
  -p, --print                 Print output to stdout
  -f, --filename              Manually set the password store filename
  -k, --key                   Manually set the password store key
  -l, --logger                Set the logger type (options: compact, human, notify)
  -F, --prompt-flag           Flag passed to COMMAND for prompting the user
      --file-prompt           Prompt message when choosing a password store filename
      --key-prompt            Prompt message when choosing a password store key
      --mode-prompt           Prompt message when choosing pass-menu mode
  -h, --help                  Print this help message and exit

Logger Types:
  compact                     Print POSIX errors and messages through stderr (default)
  human                       Print human-readable errors and messages through stderr
  notify                      Print errors and messages through notifications

Environment Variables:
  PASSWORD_STORE_DIR          Path to the password-store directory
  PASSWORD_STORE_CLIP_TIME    Number of seconds to wait before restoring the clipboard
  PASSWORD_STORE_X_SELECTION  Name of the X selection to use for the clipboard

Examples:
  pass-menu -- fzf
  pass-menu --type -- dmenu -l 10
EOF
}


# ---------------------- #
#        ARGUMENTS       #
# ---------------------- #
expand_args () {
    local ARGS=()

    while [ -v 1 ]; do
        local ARG="${1}"; shift 1

        if [[ "${ARG}" =~ ^-[[:alnum:]] ]]; then
            # parse short options
            local LEN=${#ARG}
            local IDX

            for (( IDX = 1; IDX < LEN; IDX++ )); do
                local CHAR="${ARG:${IDX}:1}"

                ARGS+=("-${CHAR}")

                case "${CHAR}" in
                    l)
                        if (( ++IDX < LEN )); then
                            ARGS+=("${ARG:${IDX}}")
                        elif [ -v 1 ]; then
                            ARGS+=("$(shell_quote "${1}")")
                            shift 1
                        fi

                        break
                    ;;
                    F)
                        case $(( LEN - ++IDX  )) in
                            0) if [ -v 1 ]; then ARGS+=("$(shell_quote "${1}")"); shift 1; fi ;;
                            1) ARGS+=("-${ARG:${IDX}}") ;;
                            *) ARGS+=("--${ARG:${IDX}}") ;;
                        esac

                        break
                    ;;
                esac
            done
        elif [[ "${ARG}" =~ ^--[-_[:alnum:]]+$ ]]; then
            # handle long options
            ARGS+=("${ARG}")

            case "${ARG}" in
                --filename | --key | --logger | --prompt-flag | --file-prompt | --key-prompt | --mode-prompt)
                    if [ -v 1 ]; then
                        ARGS+=("$(shell_quote "${1}")")
                        shift 1
                    fi
                ;;
            esac
        elif [[ "${ARG}" =~ ^(--[-_[:alnum:]]+)=(.+)$ ]]; then
            # parse option=value pairs
            ARGS+=(
                "${BASH_REMATCH[1]}"
                "$(shell_quote "${BASH_REMATCH[2]}")"
            )
        elif [[ "${ARG}" = '--' ]]; then
            # handle options separator
            ARGS+=("${ARG}")

            while [ -v 1 ]; do
                ARGS+=("$(shell_quote "${1}")")
                shift
            done

            break
        else
            # handle values
            ARGS+=("$(shell_quote "${ARG}")")
        fi
    done

    printf '%s' "${ARGS[*]}"
}

validate_missing_arg () {
    if [ ! -v 2 ]; then
        arg_error "Missing argument to option" "${1}"
    elif [[ "${2}" =~ ^[[:blank:]]*$ ]]; then
        arg_error "Empty argument to option $(quote "${1}")" "${2}"
    fi
}

fix_prompts () {
    # skip arguments until menu command is reached
    while [ -v 1 ]; do
        if [ "${1}" = '-F' ] || [ "${1}" = '--prompt-flag' ]; then
            shift 2
        fi

        if [ "${1}" = '--' ]; then
            # handle menu command
            case "$(basename -- "${2:-}")" in
                dmenu)
                    # append colon to dmenu prompts
                    FILE_PROMPT="${FILE_PROMPT}:"
                    KEY_PROMPT="${KEY_PROMPT}:"
                    MODE_PROMPT="${MODE_PROMPT}:"
                ;;
                fzf)
                    # append angle brackets to fzf prompts
                    FILE_PROMPT="${FILE_PROMPT}> "
                    KEY_PROMPT="${KEY_PROMPT}> "
                    MODE_PROMPT="${MODE_PROMPT}> "
                ;;
            esac

            break
        fi

        shift 1
    done
}

parse_args () {
    # expand arguments
    local ARGS; ARGS="$(expand_args "${@}")"

    eval set -- ${ARGS}

    # check for help flag
    local ARG
    for ARG in "${@}"; do
        case "${ARG}" in
            # print help and exit
            -h | --help)
                print_help
                exit 0
            ;;
            # stop searching after argument separator
            --) break ;;
        esac
    done

    # fix prompts
    fix_prompts "${@}"

    # parse arguments
    while [ -v 1 ]; do
        case "${1}" in
            -t | --type)
                PASS_MODE="type"
                shift 1
            ;;
            -c | --clip)
                PASS_MODE="clip"
                shift 1
            ;;
            -p | --print)
                PASS_MODE="print"
                shift 1
            ;;
            -f  | --filename)
                validate_missing_arg "${@}"

                FILE_NAME="${2}"
                shift 2
            ;;
            -k  | --key)
                validate_missing_arg "${@}"

                KEY_NAME="${2}"
                shift 2
            ;;
            -l | --logger)
                validate_missing_arg "${@}"

                if ! oneof "${2}" 'compact' 'human' 'notify'; then
                    arg_error "Invalid value for ${1}" "${2}"
                fi

                LOG_TYPE="${2}"
                shift 2
            ;;
            -F | --prompt-flag)
                validate_missing_arg "${@}"

                PROMPT_FLAG="${2}"
                shift 2
            ;;
            --file-prompt)
                validate_missing_arg "${@}"

                FILE_PROMPT="${2}"
                shift 2
            ;;
            --key-prompt)
                validate_missing_arg "${@}"

                KEY_PROMPT="${2}"
                shift 2
            ;;
            --mode-prompt)
                validate_missing_arg "${@}"

                MODE_PROMPT="${2}"
                shift 2
            ;;
            --)
                shift 1

                if [ ! -v 1 ]; then
                    break
                elif [[ "${1}" =~ ^[[:blank:]]*$ ]]; then
                    arg_error "Empty executable in menu command" "${1}"
                elif ! command -v "${1}" &>/dev/null; then
                    arg_error "Invalid executable in menu command" "${1}"
                fi

                MENU_CMD=("${@}")
                break
            ;;
            -*) arg_error "Unknown flag" "${1}" ;;
            *)  arg_error "Invalid position for value" "${1}" ;;
        esac
    done

    # validate required arguments
    if [ ${#MENU_CMD[@]} = 0 ] &&
       ! ([ -n "${FILE_NAME}" ] &&
          [ -n "${KEY_NAME}" ] &&
          ([ "${PASS_MODE}" != ask ] || is_action_key "${KEY_NAME}"))
    then
        read_error arguments "Missing menu command"
    fi
}


# ---------------------- #
#          MAIN          #
# ---------------------- #
call_menu_cmd () {
    local PROMPT="${1}"

    if [ -n "${PROMPT_FLAG}" ]; then
        "${MENU_CMD[@]}" "${PROMPT_FLAG}" "${PROMPT}"
    else
        "${MENU_CMD[@]}"
    fi
}

main () {
    # parse arguments
    parse_args "${@}"

    # validate environment variables
    if [ ! -d "${PASSWORD_STORE_DIR}" ]; then
        read_error "environment variables" \
                   "Invalid directory in PASSWORD_STORE_DIR: $(quote "${PASSWORD_STORE_DIR}")"
    fi

    if [[ ! "${PASSWORD_STORE_CLIP_TIME}" =~ ^0*([1-9][0-9]*)$ ]]; then
        read_error "environment variables" \
                   "Invalid duration in PASSWORD_STORE_CLIP_TIME: $(quote "${PASSWORD_STORE_CLIP_TIME}")"
    fi

    if ! oneof "${PASSWORD_STORE_X_SELECTION}" 'primary' 'secondary' 'clipboard'; then
        read_error "environment variables" \
                   "Invalid value in PASSWORD_STORE_X_SELECTION: $(quote "${PASSWORD_STORE_X_SELECTION}")"
    fi

    # interactively get filename
    if [ -z "${FILE_NAME}" ]; then
        list_pass_filenames | call_menu_cmd "${FILE_PROMPT}" | readstring FILE_NAME
    fi

    if ! is_pass_file "${FILE_NAME}"; then
        read_error filename "File doesn't exist: $(quote "${FILE_NAME}")"
    fi

    # read and parse file
    read_pass_file "${FILE_NAME}" | readarray FILE

    parse_file

    if [ ${#DATA[@]} = 0 ]; then
        read_error file "File doesn't have any data: $(quote "${FILE_NAME}")"
    fi

    # interactively get key
    if [ -z "${KEY_NAME}" ]; then
        list_keys | call_menu_cmd "${KEY_PROMPT}" | readstring KEY_NAME
    fi

    if ! has_value "${KEY_NAME}"; then
        read_error key "Key doesn't exist in ${FILE_NAME}): $(quote "${KEY_NAME}")"
    fi

    # early return on on action keys
    if is_action_key "${KEY_NAME}"; then
        get_raw_value "${KEY_NAME}" | run_action
        return
    fi

    # interactively get mode if not specified
    if [ "${PASS_MODE}" = ask ]; then
        printf 'type\nclip\nprint\n' | call_menu_cmd "${MODE_PROMPT}" | readstring PASS_MODE

        if ! oneof "${PASS_MODE}" 'type' 'clip' 'print'; then
            read_error action "Invalid action: ${PASS_MODE}"
        fi
    fi

    # run based on mode
    case "${PASS_MODE}" in
        type)  get_value "${KEY_NAME}" | type_str ;;
        clip)  get_value "${KEY_NAME}" | clip "${KEY_NAME}" ;;
        print) get_value "${KEY_NAME}" ;;
        *)     internal_error "Invalid PASS_MODE in main"
    esac
}

main "${@}"
